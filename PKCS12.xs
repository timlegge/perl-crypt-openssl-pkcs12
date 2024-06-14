#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include "ppport.h"

#include <openssl/crypto.h>
#include <openssl/err.h>
#include <openssl/pem.h>
#include <openssl/pkcs12.h>
#include <openssl/x509.h>
#include <openssl/ssl.h>
#if OPENSSL_VERSION_NUMBER >= 0x30000000L
#include <openssl/provider.h>
#endif
#define NOKEYS          0x1
#define NOCERTS         0x2
#define INFO            0x4
#define CLCERTS         0x8
#define CACERTS         0x10

#if OPENSSL_VERSION_NUMBER < 0x10100000L
#define PKCS12_SAFEBAG_get0_safes(o) ((o)->value.safes)
#define PKCS12_SAFEBAG_get0_p8inf(o) ((o)->value.keybag)
#define PKCS12_SAFEBAG_get0_attr PKCS12_get_attr
#define PKCS12_SAFEBAG_get_bag_nid M_PKCS12_cert_bag_type
#define PKCS12_SAFEBAG_get_nid M_PKCS12_bag_type
#define PKCS12_SAFEBAG_get1_cert PKCS12_certbag2x509
#define CONST_X509_ALGOR X509_ALGOR
#define CONST_X509_SIG X509_SIG
#define CONST_ASN1_TYPE ASN1_TYPE
#define CONST_STACK_OF(o) STACK_OF(o)
#define CONST_X509_NAME X509_NAME
#define CONST_ASN1_INTEGER ASN1_INTEGER
#define CONST_ASN1_OBJECT ASN1_OBJECT
#define CONST_ASN1_OCTET_STRING ASN1_OCTET_STRING
#define CONST_VOID void
#else
#define CONST_X509_ALGOR const X509_ALGOR
#define CONST_X509_SIG const X509_SIG
#define CONST_ASN1_TYPE const ASN1_TYPE
#define CONST_STACK_OF(o) const STACK_OF(o)
#define CONST_X509_NAME const X509_NAME
#define CONST_ASN1_INTEGER const ASN1_INTEGER
#define CONST_ASN1_OBJECT const ASN1_OBJECT
#define CONST_ASN1_OCTET_STRING const ASN1_OCTET_STRING
#define CONST_VOID const void
#endif

#if OPENSSL_VERSION_NUMBER < 0x10102000L
#define CONST_PKCS8_PRIV_KEY_INFO PKCS8_PRIV_KEY_INFO
#else
#define CONST_PKCS8_PRIV_KEY_INFO const PKCS8_PRIV_KEY_INFO
#endif

#if OPENSSL_VERSION_NUMBER < 0x30000000L
#if OPENSSL_VERSION_NUMBER > 0x10100000L
#include "p12_local.h"
#endif
#define PKCS12_SAFEBAG_get0_bag_type(o) (o->value.bag->type)
#define PKCS12_SAFEBAG_get0_bag_obj(o) (o->value.bag->value.other)
#endif

const EVP_CIPHER *enc;
int dump_certs_pkeys_bags(pTHX_ BIO *out, CONST_STACK_OF(PKCS12_SAFEBAG) *bags,
                           const char *pass, int passlen, int options,
                           char *pempass, const EVP_CIPHER *enc, HV* hash);
static int alg_print(pTHX_ BIO *bio, CONST_X509_ALGOR *alg, HV* hash);
void print_attribute(pTHX_ BIO *out, CONST_ASN1_TYPE *av, char **value);
int print_attribs(pTHX_ BIO *out, CONST_STACK_OF(X509_ATTRIBUTE) *attrlst, const char *name, HV *hash);
void hex_prin(BIO *out, unsigned char *buf, int len);
void dump_cert_text(BIO *out, X509 *x);
SV * get_cert_subject_name(pTHX_ X509 *x);
SV * get_cert_issuer_name(pTHX_ X509 *x);

/* fake our package name */
typedef PKCS12*  Crypt__OpenSSL__PKCS12;

void croakSSL(char* p_file, int p_line) {

  const char* errorReason;

  /* Just return the top error on the stack */
  errorReason = ERR_reason_error_string(ERR_get_error());

  ERR_clear_error();

  croak("%s:%d: OpenSSL error: %s", p_file, p_line, errorReason);
}

#define CHECK_OPEN_SSL(p_result) if (!(p_result)) croakSSL(__FILE__, __LINE__);

EVP_PKEY* _load_pkey(char* keyString, EVP_PKEY*(*p_loader)(BIO*, EVP_PKEY**, pem_password_cb*, void*)) {

  EVP_PKEY* pkey;
  BIO* stringBIO;

  if (!strncmp(keyString, "----", 4)) {

    CHECK_OPEN_SSL(stringBIO = BIO_new_mem_buf(keyString, strlen(keyString)));

  } else {

    CHECK_OPEN_SSL(stringBIO = BIO_new_file(keyString, "r"));
  }

  pkey = p_loader(stringBIO, NULL, NULL, NULL);

  (void)BIO_set_close(stringBIO, BIO_CLOSE);
  BIO_free_all(stringBIO);

  CHECK_OPEN_SSL(pkey);
  return pkey;
}

STACK_OF(X509)* _load_cert_chain(char* keyString, STACK_OF(X509_INFO)*(*p_loader)(BIO*, STACK_OF(X509_INFO)*, pem_password_cb*, void*)) {
  int i;
  STACK_OF(X509_INFO) *xis = NULL;
  X509_INFO *xi = NULL;
  BIO* stringBIO;
  STACK_OF(X509) *stack = sk_X509_new_null();

  if (!strncmp(keyString, "----", 4)) {
    CHECK_OPEN_SSL(stringBIO = BIO_new_mem_buf(keyString, strlen(keyString)));
  } else {
    CHECK_OPEN_SSL(stringBIO = BIO_new_file(keyString, "r"));
  }

  xis = p_loader(stringBIO, NULL, NULL, NULL);
  for (i = 0; i < sk_X509_INFO_num(xis); i++) {
    xi = sk_X509_INFO_value(xis, i);
    if (xi->x509 != NULL && stack != NULL) {
      CHECK_OPEN_SSL(xi->x509);
      if (!sk_X509_push(stack, xi->x509))
        goto end;
      xi->x509 = NULL;
    }
  }

 end:
  sk_X509_INFO_pop_free(xis, X509_INFO_free);
  (void)BIO_set_close(stringBIO, BIO_CLOSE);
  BIO_free_all(stringBIO);

  return stack;
}

#if OPENSSL_VERSION_NUMBER >= 0x30000000L
long bio_write_cb(struct bio_st *bm, int m, const char *ptr, size_t len, int l, long x, int y, size_t *processed) {
#else
long bio_write_cb(struct bio_st *bm, int m, const char *ptr, int len, long x, long y) {
#endif
/* stolen from OpenSSL.xs */

  if (m == BIO_CB_WRITE) {
    SV *sv = (SV *) BIO_get_callback_arg(bm);
    sv_catpvn(sv, ptr, len);
  }

  if (m == BIO_CB_PUTS) {
    SV *sv = (SV *) BIO_get_callback_arg(bm);
    len = strlen(ptr);
    sv_catpvn(sv, ptr, len);
  }

  return len;
}

static BIO* sv_bio_create(void) {

  SV *sv = newSVpvn("",0);

  /* create an in-memory BIO abstraction and callbacks */
  BIO *bio = BIO_new(BIO_s_mem());

#if OPENSSL_VERSION_NUMBER >= 0x30000000L
  BIO_set_callback_ex(bio, bio_write_cb);
#else
  BIO_set_callback(bio, bio_write_cb);
#endif
  BIO_set_callback_arg(bio, (void *)sv);

  return bio;
}

static SV* sv_bio_final(BIO *bio) {

  SV* sv;

  (void)BIO_flush(bio);
  sv = (SV *)BIO_get_callback_arg(bio);
  BIO_set_callback_arg(bio, (void *)NULL);
#if OPENSSL_VERSION_NUMBER >= 0x30000000L
  BIO_set_callback_ex(bio, (void *)NULL);
#else
  BIO_set_callback(bio, (void *)NULL);
#endif
  BIO_free_all(bio);

  if (!sv) sv = &PL_sv_undef;

  return sv;
}

static void sv_bio_error(BIO *bio) {

  SV* sv = (SV *)BIO_get_callback_arg(bio);
  if (sv) sv_free(sv);

  BIO_free_all (bio);
}

static const char *ssl_error(void) {
  BIO *bio;
  SV *sv;
  STRLEN l;

  bio = sv_bio_create();
  ERR_print_errors(bio);
  sv = sv_bio_final(bio);
  ERR_clear_error();
  return SvPV(sv, l);
}

/* these are trimmed from their openssl/apps/pkcs12.c counterparts */
int dump_certs_pkeys_bag (pTHX_ BIO *bio, PKCS12_SAFEBAG *bag, const char *pass, int passlen, int options, char *pempass, HV * bag_hv) {

  EVP_PKEY *pkey;
  X509 *x509;
  CONST_PKCS8_PRIV_KEY_INFO *p8;
  CONST_STACK_OF(X509_ATTRIBUTE) *bag_attrs;
  CONST_STACK_OF(X509_ATTRIBUTE) *key_attrs;

#if OPENSSL_VERSION_NUMBER >= 0x10100000L
  bag_attrs = PKCS12_SAFEBAG_get0_attrs(bag);
#else
  bag_attrs = bag->attrib;
#endif

#ifndef OPENSSL_NO_DES
  EVP_CIPHER *default_enc = (EVP_CIPHER *)EVP_des_ede3_cbc();
  enc = NULL; /*default_enc; */
#else
  EVP_CIPHER *default_enc = (EVP_CIPHER *)EVP_aes_256_cbc();
  enc = default_enc;
#endif

  switch (PKCS12_SAFEBAG_get_nid(bag)) {

    case NID_keyBag: ;

      if (options & NOKEYS) return 1;

#if OPENSSL_VERSION_NUMBER > 0x10100000L
      p8 = PKCS12_SAFEBAG_get0_p8inf(bag);
      if (!(pkey = EVP_PKCS82PKEY (p8))) return 0;
      key_attrs = PKCS8_pkey_get0_attrs(p8);
#else
      p8 = bag->value.keybag;
      if (!(pkey = EVP_PKCS82PKEY(p8)))
             return 0;
      key_attrs = p8->attributes;
#endif

      if (options & INFO) {
        if (bag_hv) {
          SV * value = newSVpvn("key_bag", strlen("key_bag"));
          if((hv_store(bag_hv, "type", strlen("type"), value, 0)) == NULL)
            croak("unable to add certificate_bag to the bag_hv");

          /* Assign the output to a temporary BIO and free after it is saved to key_sv */
          BIO *keybio = sv_bio_create();
          PEM_write_bio_PrivateKey (keybio, pkey, enc, NULL, 0, NULL, pempass);
          SV * key_sv = sv_bio_final(keybio);

          if((hv_store(bag_hv, "key", strlen("key"), key_sv, 0)) == NULL)
            croak("unable to add certificate_bag to the bag_hv");
          print_attribs(aTHX_ bio, key_attrs, "Key Attributes", bag_hv);
        } else {
          BIO_printf(bio, "Key bag\n");
          print_attribs(aTHX_ bio, key_attrs, "Key Attributes", NULL);
          PEM_write_bio_PrivateKey (bio, pkey, enc, NULL, 0, NULL, pempass);
        }
      } else {
        PEM_write_bio_PrivateKey (bio, pkey, enc, NULL, 0, NULL, pempass);
      }

      EVP_PKEY_free(pkey);

      break;

    case NID_pkcs8ShroudedKeyBag: ;

      if (options & NOKEYS) return 1;
#if OPENSSL_VERSION_NUMBER > 0x10100000L
      if ((p8 = PKCS12_decrypt_skey(bag, pass, passlen)) == NULL)
        return 0;
      if ((pkey = EVP_PKCS82PKEY (p8)) == NULL) {
        PKCS8_PRIV_KEY_INFO_free(p8);
        return 0;
      }
      key_attrs = PKCS8_pkey_get0_attrs(p8);
#else
      if (!(p8 = PKCS12_decrypt_skey(bag, pass, passlen)))
             return 0;
         if (!(pkey = EVP_PKCS82PKEY(p8))) {
             PKCS8_PRIV_KEY_INFO_free(p8);
             return 0;
         }
      key_attrs = p8->attributes;
#endif
      if (options & INFO) {
#if OPENSSL_VERSION_NUMBER > 0x10100000L
        CONST_X509_SIG *tp8;
        CONST_X509_ALGOR *tp8alg;

        tp8 = PKCS12_SAFEBAG_get0_pkcs8(bag);
        X509_SIG_get0(tp8, &tp8alg, NULL);
#else
        CONST_X509_ALGOR *tp8alg;	
	tp8alg = bag->value.shkeybag->algor;
#endif
        if (bag_hv) {
          SV * value = newSVpvn("shrouded_bag", strlen("shrouded_bag"));
          HV * parameters_hv = newHV();;
          if((hv_store(bag_hv, "type", strlen("type"), value, 0)) == NULL)
            croak("unable to add type to the bag_hv");
#if OPENSSL_VERSION_NUMBER > 0x10000000L
          alg_print(aTHX_ bio, tp8alg, parameters_hv);
#endif
          print_attribs(aTHX_ bio, bag_attrs, "Bag Attributes", bag_hv);
          if((hv_store(bag_hv, "parameters", strlen("parameters"), newRV_inc((SV *) parameters_hv), 0)) == NULL)
            croak("unable to add bag_attributes to the bag_hv");
        } else {
          BIO_printf(bio, "Shrouded Keybag: ");
//#if OPENSSL_VERSION_NUMBER > 0x10100000L
          alg_print(aTHX_ bio, tp8alg, NULL);
//#endif
          print_attribs(aTHX_ bio, bag_attrs, "Bag Attributes", NULL);
        }
      }
      if (options & INFO) {
        if (bag_hv) {
          SV * value = newSVpvn("shrouded_keybag", strlen("shrouded_keybag"));
          if((hv_store(bag_hv, "type", strlen("type"), value, 0)) == NULL)
            croak("unable to add type to the bag_hv");

          print_attribs(aTHX_ bio, key_attrs, "Key Attributes", bag_hv);

          /* Assign the output to a temporary BIO and free after it is saved to key_sv */
          BIO *keybio = sv_bio_create();
          PEM_write_bio_PrivateKey (keybio, pkey, enc, NULL, 0, NULL, pempass);
          SV * key_sv = sv_bio_final(keybio);

          if((hv_store(bag_hv, "key", strlen("key"), key_sv, 0)) == NULL)
            croak("unable to add certificate_bag to the bag_hv");
        } else {
          print_attribs(aTHX_ bio, key_attrs, "Key Attributes", NULL);
          PEM_write_bio_PrivateKey (bio, pkey, enc, NULL, 0, NULL, pempass);
        }
      } else {
        PEM_write_bio_PrivateKey (bio, pkey, enc, NULL, 0, NULL, pempass);
      }

      PKCS8_PRIV_KEY_INFO_free(p8);

      EVP_PKEY_free(pkey);

      break;

    case NID_certBag:

      if (options & NOCERTS) return 1;

      if (PKCS12_SAFEBAG_get0_attr(bag, NID_localKeyID)) {

        if (options & CACERTS) return 1;

      } else if (options & CLCERTS) {

        return 1;
      }

      if (PKCS12_SAFEBAG_get_bag_nid(bag) != NID_x509Certificate) return 1;

      if ((x509 = PKCS12_SAFEBAG_get1_cert(bag)) == NULL) return 0;
      if (options & INFO) {
        if (bag_hv) {
          SV * value = newSVpvn("certificate_bag", strlen("certificate_bag"));
          print_attribs(aTHX_ bio, bag_attrs, "Bag Attributes", bag_hv);
          if((hv_store(bag_hv, "type", strlen("type"), value, 0)) == NULL)
            croak("unable to add type to the bag_hv");
          if((hv_store(bag_hv, "subject", strlen("subject"), get_cert_subject_name(aTHX_ x509), 0)) == NULL)
            croak("unable to add subject to the bag_hv");
          if((hv_store(bag_hv, "issuer", strlen("issuer"), get_cert_issuer_name(aTHX_ x509), 0)) == NULL)
            croak("unable to add issuer to the bag_hv");
          BIO *keybio = sv_bio_create();
          PEM_write_bio_X509 (keybio, x509);
          SV * key_sv = sv_bio_final(keybio);
          if((hv_store(bag_hv, "cert", strlen("cert"), key_sv, 0)) == NULL)
            croak("unable to add certificate_bag to the bag_hv");
        } else
        {
          BIO_printf(bio, "Certificate bag\n");
          print_attribs(aTHX_ bio, bag_attrs, "Bag Attributes", NULL);
          dump_cert_text(bio, x509);
          PEM_write_bio_X509 (bio, x509);
        }
      } else {
        PEM_write_bio_X509 (bio, x509);
      }

      X509_free(x509);

      break;

    case NID_secretBag:
        //FIXME: Not sure how to test this
        if (options & INFO) {
          BIO_printf(bio, "Secret bag\n");
        if (bag_hv){
          print_attribs(aTHX_ bio, bag_attrs, "Bag Attributes", bag_hv);
        }
        else
          print_attribs(aTHX_ bio, bag_attrs, "Bag Attributes", NULL);
          BIO_printf(bio, "Bag Type: ");
        }
        i2a_ASN1_OBJECT(bio, PKCS12_SAFEBAG_get0_bag_type(bag));
        if (options & INFO) {
          char * attribute_value = NULL;
          if(bag_hv) {
            Newx(attribute_value, 0, char);
            print_attribute(aTHX_ bio, PKCS12_SAFEBAG_get0_bag_obj(bag), &attribute_value);
            if(hv_store(bag_hv, "attribute_here", strlen("attribute_here"), newSVpvn(attribute_value, strlen(attribute_value)), 0) == NULL)
              croak("unable to add MAC to the bag_hv");
          } else {
            BIO_printf(bio, "\nBag Value: ");
            print_attribute(aTHX_ bio, PKCS12_SAFEBAG_get0_bag_obj(bag), &attribute_value);
          }
          Safefree(attribute_value);
        }
        break;
    case NID_safeContentsBag:
        //FIXME: Not sure how to test this
        if (options & INFO) {
          BIO_printf(bio, "Safe Contents bag\n");
          if(bag_hv) {
            print_attribs(aTHX_ bio, bag_attrs, "Bag Attributes", bag_hv);
          } else {
            print_attribs(aTHX_ bio, bag_attrs, "Bag Attributes", NULL);
          }
          dump_certs_pkeys_bags(aTHX_ bio, PKCS12_SAFEBAG_get0_safes(bag),
                                      pass, passlen, options, pempass, enc, bag_hv);
        }
        break;
  }

  return 1;
}

int dump_certs_pkeys_bags(pTHX_ BIO *bio, CONST_STACK_OF(PKCS12_SAFEBAG) *bags, const char *pass, int passlen, int options, char *pempass, const EVP_CIPHER *enc, HV * hash) {

  int i;

  AV * bags_av = NULL;
  HV * bag_hv = NULL;
  if(hash) {
    bags_av = newAV();
  }
  for (i = 0; i < sk_PKCS12_SAFEBAG_num(bags); i++) {
    if(hash)
      bag_hv = newHV();
    if (!dump_certs_pkeys_bag (aTHX_ bio, sk_PKCS12_SAFEBAG_value (bags, i), pass, passlen, options, pempass, bag_hv)) {
      return 0;
    }
    if(hash)
      av_push(bags_av, newRV_inc((SV *) bag_hv));
  }
  if (hash) {
    if((hv_store(hash, "bags", strlen("bags"), newRV_inc((SV *) bags_av), 0)) == NULL)
      croak("unable to add bags to the hash");
  }
  return 1;
}

int dump_certs_keys_p12(pTHX_ BIO *bio, PKCS12 *p12, char *pass, int passlen, int options, char *pempass, HV * orig_hash) {

  STACK_OF(PKCS7) *asafes;
  STACK_OF(PKCS12_SAFEBAG) *bags;

  int i, bagnid;
  PKCS7 *p7;
  HV * bag_hv = NULL;
  HV * parameters_hv = NULL;

  if ((asafes = PKCS12_unpack_authsafes(p12)) == NULL) {
    croak("Unable to PKCS12_unpack_authsafes");
    return 0;
  }

  for (i = 0; i < sk_PKCS7_num(asafes); i++) {

  if (orig_hash) {
    parameters_hv = newHV();
    bag_hv = newHV();
  }

    p7 = sk_PKCS7_value(asafes, i);

    bagnid = OBJ_obj2nid(p7->type);

    if (bagnid == NID_pkcs7_data) {

      if (options & INFO) {
        if (orig_hash) {
          bag_hv = newHV();
          if((hv_store(orig_hash, "pkcs7_data", strlen("pkcs7_data"), newRV_inc((SV *) bag_hv), 0)) == NULL)
            croak("unable to add pkcs7_data to the orig_hash");
        }
        else
          BIO_printf(bio, "PKCS7 Data\n");
      }
      bags = PKCS12_unpack_p7data(p7);

    } else if (bagnid == NID_pkcs7_encrypted) {
      if (options & INFO) {
        if (orig_hash) {
          bag_hv = newHV();

          if (p7->d.encrypted != NULL)
            alg_print(aTHX_ bio, p7->d.encrypted->enc_data->algorithm, parameters_hv);
          if((hv_store(bag_hv, "parameters", strlen("parameters"), newRV_inc((SV *) parameters_hv), 0)) == NULL)
            croak("unable to add parameters to the hash");
          if((hv_store(orig_hash, "pkcs7_encrypted_data", strlen("pkcs7_encrypted_data"), newRV_inc((SV *) bag_hv), 0)) == NULL)
            croak("unable to add pkcs7_encrypted_data to the orig_hash");
        } else {
          BIO_printf(bio, "PKCS7 Encrypted data: ");
          if (p7->d.encrypted == NULL) {
            BIO_printf(bio, "<no data>\n");
          } else {
            alg_print(aTHX_ bio, p7->d.encrypted->enc_data->algorithm, NULL);
          }
        }
      }
      bags = PKCS12_unpack_p7encdata(p7, pass, passlen);

    } else {
      continue;
    }

    if (bags == NULL) return 0;

    if (!dump_certs_pkeys_bags(aTHX_ bio, bags, pass, passlen, options, pempass, enc, bag_hv)) {

      sk_PKCS12_SAFEBAG_pop_free(bags, PKCS12_SAFEBAG_free);
      return 0;
    }

    sk_PKCS12_SAFEBAG_pop_free(bags, PKCS12_SAFEBAG_free);
  }

  sk_PKCS7_pop_free(asafes, PKCS7_free);

  return 1;
}
# define B_FORMAT_TEXT   0x8000
# define FORMAT_TEXT    (1 | B_FORMAT_TEXT)     /* Generic text */
int FMT_istext(int format)
{
  return (format & B_FORMAT_TEXT) == B_FORMAT_TEXT;
}

BIO *dup_bio_err(int format)
{
  BIO *b = BIO_new_fp(stderr,
                      BIO_NOCLOSE | (FMT_istext(format) ? BIO_FP_TEXT : 0));

  return b;
}

static unsigned long nmflag = 0;
static char nmflag_set = 0;
# define XN_FLAG_SPC_EQ          (1 << 23)/* Put spaces round '=' */

unsigned long get_nameopt(void)
{
  return
      nmflag_set ? nmflag : XN_FLAG_SEP_CPLUS_SPC | ASN1_STRFLGS_UTF8_CONVERT | XN_FLAG_SPC_EQ;
}

void print_name(BIO *out, const char *title, CONST_X509_NAME *nm)
{
  char *buf;
  char mline = 0;
  int indent = 0;
  unsigned long lflags = get_nameopt();

  if (out == NULL)
    return;
  if (title != NULL)
    BIO_puts(out, title);
  if ((lflags & XN_FLAG_SEP_MASK) == XN_FLAG_SEP_MULTILINE) {
    mline = 1;
    indent = 4;
  }
  if (lflags == XN_FLAG_COMPAT) {
    buf = X509_NAME_oneline(nm, 0, 0);
    BIO_puts(out, buf);
    BIO_puts(out, "\n");
    OPENSSL_free(buf);
  } else {
    if (mline)
      BIO_puts(out, "\n");
      X509_NAME_print_ex(out, nm, indent, lflags);

      BIO_puts(out, "\n");
  }
}

void dump_cert_text(BIO *out, X509 *x)
{
  print_name(out, "subject=", X509_get_subject_name(x));
  print_name(out, "issuer=", X509_get_issuer_name(x));
}

SV * get_cert_subject_name(pTHX_ X509 *x)
{
  BIO *bio = sv_bio_create();

  print_name(bio, "", X509_get_subject_name(x));
  return sv_bio_final(bio);
}

SV * get_cert_issuer_name(pTHX_ X509 *x)
{
  BIO *bio = sv_bio_create();

  print_name(bio, "", X509_get_issuer_name(x));
  return sv_bio_final(bio);
}

void get_hex(char *out, unsigned char *buf, int len)
{
  int i;
  for (i = 0; i < len; i++) {
    if (i == (len-1))
      out += sprintf(out, "%02X", buf[i]);
    else
      out += sprintf(out, "%02X ", buf[i]);
  }
}

void hex_prin(BIO *out, unsigned char *buf, int len)
{
  int i;
  for (i = 0; i < len; i++)
  BIO_printf(out, "%02X ", buf[i]);
}

/* Generalised x509 attribute value print */

void print_attribute(pTHX_ BIO *out, CONST_ASN1_TYPE *av, char **attribute)
{
  char *value;
  const char *ln;
  char objbuf[80];
  switch (av->type) {
  case V_ASN1_BMPSTRING:
    value = OPENSSL_uni2asc(av->value.bmpstring->data,
                                av->value.bmpstring->length);
    if(*attribute != NULL) {
      Renew(*attribute, av->value.bmpstring->length, char);
      strncpy(*attribute, value, av->value.bmpstring->length);
    } else {
      BIO_printf(out, "%s\n", value);
      OPENSSL_free(value);
    }
    break;

  case V_ASN1_UTF8STRING:
    if(*attribute != NULL) {
      Renew(*attribute, av->value.utf8string->length, char);
      strncpy(*attribute, (const char * ) av->value.utf8string->data, av->value.utf8string->length);
    } else {
      BIO_printf(out, "%.*s\n", av->value.utf8string->length,
                   av->value.utf8string->data);
    }
    break;

  case V_ASN1_OCTET_STRING:
    if(*attribute != NULL) {
      Renew(*attribute, av->value.octet_string->length * 4, char);
      get_hex(*attribute, av->value.octet_string->data, av->value.octet_string->length);
    } else {
      hex_prin(out, av->value.octet_string->data,
                 av->value.octet_string->length);
      BIO_printf(out, "\n");
    }
    break;

  case V_ASN1_BIT_STRING:
    if(*attribute != NULL) {
      Renew(*attribute, av->value.bit_string->length *4, char);
      get_hex(*attribute, av->value.bit_string->data, av->value.bit_string->length);
    } else {
      hex_prin(out, av->value.bit_string->data,
                 av->value.bit_string->length);
      BIO_printf(out, "\n");
    }
    break;

  case V_ASN1_OBJECT:
    ln = OBJ_nid2ln(OBJ_obj2nid(av->value.object));
    if (!ln)
      ln = "";
    OBJ_obj2txt(objbuf, sizeof(objbuf), av->value.object, 1);
    if(*attribute != NULL) {
      Renew(*attribute, strlen(ln), char);
      strncpy(*attribute, ln, strlen(*attribute));
    } else {
      BIO_printf(out, "%s (%s)", ln, objbuf);
      BIO_printf(out, "\n");
    }
    break;

  default:
    BIO_printf(out, "<Unsupported tag %d>\n", av->type);
    break;
  }
}

/* Generalised attribute print: handle PKCS#8 and bag attributes */
int print_attribs(pTHX_ BIO *out, CONST_STACK_OF(X509_ATTRIBUTE) *attrlst,
                  const char *name, HV * hash)
{
  X509_ATTRIBUTE *attr;
  ASN1_TYPE *av;
  int i, j, attr_nid;
  AV * bags_av = newAV();
  if (!attrlst) {
    if(hash) {
      /* FIXME: May need to change attribute storage for empty attributes */
      /*SV * value = newSVpvn("<No Attributes>", strlen("<No Attributes>")); */
      /*if((hv_store(hash, "attributes", strlen("attributes"), newRV_inc((SV *) bags_av), 0)) == NULL) */
      /*  croak("unable to add attributes to the hash"); */
    } else
      BIO_printf(out, "%s: <No Attributes>\n", name);
    return 1;
  }
  if (!sk_X509_ATTRIBUTE_num(attrlst)) {
    if(hash) {
      /* FIXME: May need to change attribute storage for empty attributes */
      /*if((hv_store(hash, "attributes", strlen("attributes"), newRV_inc((SV *) bags_av), 0)) == NULL) */
      /*  croak("unable to add attributes to the hash"); */
    } else
      BIO_printf(out, "%s: <TIMEmpty Attributes>\n", name);
    return 1;
  }
  if(!hash)
    BIO_printf(out, "%s\n", name);

  HV * bag_hv = newHV();
  for (i = 0; i < sk_X509_ATTRIBUTE_num(attrlst); i++) {
    ASN1_OBJECT *attr_obj;
  if (attrlst == NULL)
	return 1;
    attr = sk_X509_ATTRIBUTE_value(attrlst, i);
    attr_obj = X509_ATTRIBUTE_get0_object(attr);
    attr_nid = OBJ_obj2nid(attr_obj);
    if (attr_nid == NID_undef && !hash) {
      i2a_ASN1_OBJECT(out, attr_obj);
      BIO_printf(out, ": ");
    } else {
      if (!hash) {
        /* Print the name of the attributes */
        BIO_printf(out, "    ");
        BIO_printf(out, "%s: ", OBJ_nid2ln(attr_nid));
      }
    }

    if (X509_ATTRIBUTE_count(attr)) {
      for (j = 0; j < X509_ATTRIBUTE_count(attr); j++)
      {
        av = X509_ATTRIBUTE_get0_type(attr, j);
        char *attribute_value = NULL;
        if(hash) {
          Newx(attribute_value, 0, char);
          print_attribute(aTHX_ out, av, &attribute_value);
          const char * attribute_id = NULL;
          if (attr_nid != NID_undef) {
            /* Save the attribute name and value to the hash */
            attribute_id = OBJ_nid2ln(attr_nid);
            if (attribute_id) {
              if((hv_store(bag_hv, attribute_id, strlen(attribute_id), newSVpvn(attribute_value, strlen(attribute_value)), 0)) == NULL)
                croak("unable to add MAC to the hash");
            }
          }
        } else {
          print_attribute(aTHX_ out, av, &attribute_value);
        }
        Safefree(attribute_value);
        av_push(bags_av, newRV_inc((SV *) bag_hv));
      }
    } else {
      BIO_printf(out, "<No Values>\n");
    }
  }
  if (hash) {
    if((hv_store(hash, "bag_attributes", strlen("bag_attributes"), newRV_inc((SV *) bag_hv), 0)) == NULL)
      croak("unable to add bags to the hash");
  }
  return 1;
}

static int alg_print(pTHX_ BIO *bio, CONST_X509_ALGOR *alg, HV * parameters_hash)
{
  int pbenid, aparamtype;
  CONST_ASN1_OBJECT *aoid;
  CONST_VOID *aparam;
  PBEPARAM *pbe = NULL;

  X509_ALGOR_get0(&aoid, &aparamtype, &aparam, alg);
  pbenid = OBJ_obj2nid(aoid);
  if (parameters_hash) {
    SV * nid_long_name = newSVpvn(OBJ_nid2ln(pbenid), strlen(OBJ_nid2ln(pbenid)));
    if((hv_store(parameters_hash, "nid_long_name", strlen("nid_long_name"), nid_long_name, 0)) == NULL)
      croak("unable to add MAC to the parameters_hash");
    SV * nid_short_name = newSVpvn(OBJ_nid2sn(pbenid), strlen(OBJ_nid2sn(pbenid)));
    if((hv_store(parameters_hash, "nid_short_name", strlen("nid_short_name"), nid_short_name, 0)) == NULL)
      croak("unable to add MAC to the parameters_hash");
  } else {
    BIO_printf(bio, "%s", OBJ_nid2ln(pbenid));
  }
  /*
  * If PBE algorithm is PBES2 decode algorithm parameters
  * for additional details.
  */
  if (pbenid == NID_pbes2) {
    PBE2PARAM *pbe2 = NULL;
    int encnid;
    if (aparamtype == V_ASN1_SEQUENCE)
      pbe2 = ASN1_item_unpack(aparam, ASN1_ITEM_rptr(PBE2PARAM));
    if (pbe2 == NULL) {
        BIO_puts(bio, ", <unsupported parameters>");
      goto done;
    }
    X509_ALGOR_get0(&aoid, &aparamtype, &aparam, pbe2->keyfunc);
    pbenid = OBJ_obj2nid(aoid);

    X509_ALGOR_get0(&aoid, NULL, NULL, pbe2->encryption);
    encnid = OBJ_obj2nid(aoid);
    if (parameters_hash) {
      SV * nid_long_name = newSVpvn(OBJ_nid2ln(pbenid), strlen(OBJ_nid2ln(pbenid)));
      if((hv_store(parameters_hash, "nid_long_name", strlen("nid_long_name"), nid_long_name, 0)) == NULL)
        croak("unable to add MAC to the parameters_hash");
      SV * nid_short_name = newSVpvn(OBJ_nid2sn(pbenid), strlen(OBJ_nid2sn(pbenid)));
      if((hv_store(parameters_hash, "nid_short_name", strlen("nid_short_name"), nid_short_name, 0)) == NULL)
        croak("unable to add MAC to the parameters_hash");
    } else
      BIO_printf(bio, ", %s, %s", OBJ_nid2ln(pbenid),
                   OBJ_nid2sn(encnid));
    /* If KDF is PBKDF2 decode parameters */
    if (pbenid == NID_id_pbkdf2) {
      PBKDF2PARAM *kdf = NULL;
      int prfnid;
      if (aparamtype == V_ASN1_SEQUENCE)
        kdf = ASN1_item_unpack(aparam, ASN1_ITEM_rptr(PBKDF2PARAM));
      if (kdf == NULL) {
        BIO_puts(bio, ", <unsupported parameters>");
        goto done;
      }

      if (kdf->prf == NULL) {
        prfnid = NID_hmacWithSHA1;
      } else {
        X509_ALGOR_get0(&aoid, NULL, NULL, kdf->prf);
        prfnid = OBJ_obj2nid(aoid);
      }
      if (parameters_hash) {
        SV * iteration = newSViv(ASN1_INTEGER_get(kdf->iter));
        if((hv_store(parameters_hash, "iteration", strlen("iteration"), iteration, 0)) == NULL)
          croak("unable to add iteration to the parameters_hash");
      } else
#if OPENSSL_VERSION_NUMBER > 0x10100000L
        BIO_printf(bio, ", Iteration %ld, PRF %s",
#else
        BIO_printf(bio, ", Iteration %ld, PRF %s",
#endif
                       ASN1_INTEGER_get(kdf->iter), OBJ_nid2sn(prfnid));
      PBKDF2PARAM_free(kdf);
#if OPENSSL_VERSION_NUMBER > 0x10100000L
#ifndef OPENSSL_NO_SCRYPT
      } else if (pbenid == NID_id_scrypt) {
        SCRYPT_PARAMS *kdf = NULL;

        if (aparamtype == V_ASN1_SEQUENCE)
          kdf = ASN1_item_unpack(aparam, ASN1_ITEM_rptr(SCRYPT_PARAMS));
        if (kdf == NULL) {
          BIO_puts(bio, ", <unsupported parameters>");
          goto done;
        }
        if (parameters_hash) {
          if((hv_store(parameters_hash, "salt_length", strlen("salt_length"), newSViv(ASN1_STRING_length(kdf->salt)), 0)) == NULL)
            croak("unable to add salt_length to the parameters_hash");
          if((hv_store(parameters_hash, "cost", strlen("cost"), newSViv(ASN1_INTEGER_get(kdf->costParameter)), 0)) == NULL)
            croak("unable to add cost to the parameters_hash");
          if((hv_store(parameters_hash, "block_size", strlen("block_size"), newSViv(ASN1_INTEGER_get(kdf->blockSize)), 0)) == NULL)
            croak("unable to add block_size to the parameters_hash");
          if((hv_store(parameters_hash, "parallelism", strlen("parallelism"), newSViv(ASN1_INTEGER_get(kdf->parallelizationParameter)), 0)) == NULL)
            croak("unable to add parallelism to the parameters_hash");
        } else
        BIO_printf(bio, ", Salt length: %d, Cost(N): %ld, "
                       "Block size(r): %ld, Parallelism(p): %ld",
                       ASN1_STRING_length(kdf->salt),
                       ASN1_INTEGER_get(kdf->costParameter),
                       ASN1_INTEGER_get(kdf->blockSize),
                       ASN1_INTEGER_get(kdf->parallelizationParameter));
        SCRYPT_PARAMS_free(kdf);
#endif
#endif
    }
    PBE2PARAM_free(pbe2);
  } else {
    if (aparamtype == V_ASN1_SEQUENCE)
      pbe = ASN1_item_unpack(aparam, ASN1_ITEM_rptr(PBEPARAM));
      if (pbe == NULL) {
        BIO_puts(bio, ", <unsupported parameters>");
        goto done;
      }
      if (parameters_hash) {
	long int val = ASN1_INTEGER_get(pbe->iter); 
        SV * iteration = newSViv(val);
        if((hv_store(parameters_hash, "iteration", strlen("iteration"), iteration, 0)) == NULL)
          croak("unable to add MAC to the parameters_hash");
      } else
#if OPENSSL_VERSION_NUMBER > 0x10100000L
        BIO_printf(bio, ", Iteration %ld", ASN1_INTEGER_get(pbe->iter));
#else
        BIO_printf(bio, ", Iteration %ld", ASN1_INTEGER_get(pbe->iter));
#endif
      PBEPARAM_free(pbe);
  }
  done:
  if(!parameters_hash)
    BIO_puts(bio, "\n");
  return 1;
}

MODULE = Crypt::OpenSSL::PKCS12    PACKAGE = Crypt::OpenSSL::PKCS12

PROTOTYPES: DISABLE

BOOT:
{
  HV *stash;
  char *name;
  int i;

  struct { char *n; I32 v; } Crypt__OpenSSL__PKCS12__const[] = {
    {"NOKEYS", NOKEYS},
    {"NOCERTS", NOCERTS},
    {"INFO", INFO},
    {"CLCERTS", CLCERTS},
    {"CACERTS", CACERTS},
    {Nullch,0}
  };

  OpenSSL_add_all_algorithms();

  stash = gv_stashpvn("Crypt::OpenSSL::PKCS12", 22, TRUE);

  for (i = 0; (name = Crypt__OpenSSL__PKCS12__const[i].n); i++) {
    newCONSTSUB(stash, name, newSViv(Crypt__OpenSSL__PKCS12__const[i].v));
  }
}

Crypt::OpenSSL::PKCS12
new(class)
  SV  *class

  CODE:

  if ((RETVAL = PKCS12_new()) == NULL) {
    croak("Couldn't create PKCS12_new() for class %" SVf "\n", SVfARG(class));
  }

  OUTPUT:
  RETVAL

Crypt::OpenSSL::PKCS12
new_from_string(class, string)
  SV  *class
  SV  *string

  ALIAS:
  new_from_file = 1

  PREINIT:
  BIO *bio;
  STRLEN str_len;
  char *str_ptr;
#if OPENSSL_VERSION_NUMBER >= 0x30000000L
  OSSL_PROVIDER *legacy = NULL;
  OSSL_PROVIDER *deflt = NULL;
#endif
  CODE:

  SvGETMAGIC(string);
#if OPENSSL_VERSION_NUMBER >= 0x30000000L
  legacy = OSSL_PROVIDER_load(NULL, "legacy");
    if (legacy == NULL) {
      croak("Failed to load Legacy provider\n");
    }
  deflt = OSSL_PROVIDER_load(NULL, "default");
  if (deflt == NULL) {
      OSSL_PROVIDER_unload(legacy);
      croak("Failed to load Default provider\n");
  }
#endif

  if (SvPOKp(string) || SvNOKp(string) || SvIOKp(string)) {
    if (ix == 1) {
      /* We are not looking up the SV's UTF8 bit because BIO_new_file() accepts
       * filename like syscall fopen() which mainly may accept octet sequences
       * for UTF-8 in C char*. That's what we get from using SvPV(). Also,
       * using SvPV() is not a bug if ASCII input is only allowed. */
      str_ptr = SvPV(string, str_len);
    } else {
      /* To avoid encoding mess, caller is not allowed to provide octets from
       * UTF-8 encoded strings. BIO_new_mem_buf() needs octet input only. */
      if (SvUTF8(string)) {
        croak("PKCS12_new_from: Source string must not be UTF-8 encoded (please use octets)");
      }
      str_ptr = SvPV(string, str_len);
    }
  } else {
    croak("PKCS12_new_from: Invalid Perl type for string or file was passed (0x%x).", (unsigned int)SvFLAGS(string));
  }

  if (!str_ptr || !str_len) croak("PKCS12_new_from: No string or file was passed.");

  if (ix == 1) {
    bio = BIO_new_file(str_ptr, "rb");
  } else {
    bio = BIO_new_mem_buf(str_ptr, str_len);
  }

  if (!bio) croak("Failed to create BIO");

  /* this can come in any number of ways */
  if ((RETVAL = d2i_PKCS12_bio(bio, 0)) == NULL) {
    BIO_free_all(bio);
    croak("%" SVf ": Couldn't create PKCS12 from d2i_PKCS12_BIO(): %s", SVfARG(class), ssl_error());
  }

  BIO_free_all(bio);

  OUTPUT:
  RETVAL

# This is called at per-object destruction time.
void
DESTROY(pkcs12)
  Crypt::OpenSSL::PKCS12 pkcs12;

  CODE:
  if (pkcs12) {
    PKCS12_free(pkcs12);
  }

# This is called via an END block in the Perl module to clean up initialization that happened in BOOT.
void
__PKCS12_cleanup(void)
  CODE:

  CRYPTO_cleanup_all_ex_data();
  ERR_free_strings();
#if OPENSSL_VERSION_NUMBER < 0x10100000L
  ERR_remove_state(0);
#endif
  EVP_cleanup();

SV*
as_string(pkcs12)
  Crypt::OpenSSL::PKCS12 pkcs12;

  PREINIT:
  BIO *bio;

  CODE:

  bio = sv_bio_create();

  if (!(i2d_PKCS12_bio(bio, pkcs12))) {
    sv_bio_error(bio);
    croak("i2d_PKCS12_bio: %s", ssl_error());
  }

  RETVAL = sv_bio_final(bio);

  OUTPUT:
  RETVAL

SV*
mac_ok(pkcs12, pwd = "")
  Crypt::OpenSSL::PKCS12 pkcs12
  char *pwd

  CODE:

  if (!(PKCS12_verify_mac(pkcs12, pwd, strlen(pwd)))) {
    croak("PKCS12_verify_mac: \n%s", ssl_error());
  }

  RETVAL = (PKCS12_verify_mac(pkcs12, pwd, strlen(pwd))) ? &PL_sv_yes : &PL_sv_no;

  OUTPUT:
  RETVAL

SV*
changepass(pkcs12, oldpwd = "", newpwd = "")
  Crypt::OpenSSL::PKCS12 pkcs12
  char *oldpwd
  char *newpwd

  CODE:

  if (!(PKCS12_newpass(pkcs12, oldpwd, newpwd))) {
    warn("PKCS12_newpass: %s %s\n%s", oldpwd, newpwd, ssl_error());
    RETVAL = &PL_sv_no;
  } else {
    RETVAL = &PL_sv_yes;
  }

  OUTPUT:
  RETVAL

SV*
create(pkcs12, cert_chain_pem = "", pk = "", pass = 0, file = 0, name = "PKCS12 Certificate")
  char *cert_chain_pem
  char *pk
  char *pass
  char *file
  char *name

  PREINIT:
  FILE *fp;
  EVP_PKEY* pkey;
  PKCS12 *p12;
  STACK_OF(X509) *cert_chain = NULL;

  CODE:

  pkey       = _load_pkey(pk, PEM_read_bio_PrivateKey);
  cert_chain = _load_cert_chain(cert_chain_pem, PEM_X509_INFO_read_bio);
  p12        = PKCS12_create(pass, name, pkey, sk_X509_shift(cert_chain), cert_chain, 0, 0, 0, 0, 0);

  if (!p12) {
    ERR_print_errors_fp(stderr);
    croak("Error creating PKCS#12 structure\n");
  }

  if (!(fp = fopen(file, "wb"))) {
    ERR_print_errors_fp(stderr);
    croak("Error opening file %s\n", file);
  }

  i2d_PKCS12_fp(fp, p12);
  PKCS12_free(p12);
  fclose(fp);

  RETVAL = &PL_sv_yes;

  OUTPUT:
  RETVAL


SV*
create_as_string(pkcs12, cert_chain_pem = "", pk = "", pass = 0, name = "PKCS12 Certificate")
  char *cert_chain_pem
  char *pk
  char *pass
  char *name

  PREINIT:
  BIO *bio;
  EVP_PKEY* pkey;
  PKCS12 *p12;
  STACK_OF(X509) *cert_chain = NULL;

  CODE:

  pkey       = _load_pkey(pk, PEM_read_bio_PrivateKey);
  cert_chain = _load_cert_chain(cert_chain_pem, PEM_X509_INFO_read_bio);
  p12        = PKCS12_create(pass, name, pkey, sk_X509_shift(cert_chain), cert_chain, 0, 0, 0, 0, 0);

  if (!p12) {
    ERR_print_errors_fp(stderr);
    croak("Error creating PKCS#12 structure\n");
  }

  bio = sv_bio_create();
  i2d_PKCS12_bio(bio, p12);

  RETVAL = sv_bio_final(bio);
  PKCS12_free(p12);

  OUTPUT:
  RETVAL

SV*
certificate(pkcs12, pwd = "")
  Crypt::OpenSSL::PKCS12 pkcs12
  char *pwd

  PREINIT:
  BIO *bio;
  STACK_OF(PKCS7) *asafes = NULL;

  CODE:

  bio = sv_bio_create();

  if ((asafes = PKCS12_unpack_authsafes(pkcs12)) == NULL)
        RETVAL = newSVpvn("",0);

  dump_certs_keys_p12(aTHX_ bio, pkcs12, pwd, strlen(pwd), CLCERTS|NOKEYS, NULL, NULL);

  RETVAL = sv_bio_final(bio);

  OUTPUT:
  RETVAL

SV*
private_key(pkcs12, pwd = "")
  Crypt::OpenSSL::PKCS12 pkcs12
  char *pwd

  PREINIT:
  BIO *bio;

  CODE:

  bio = sv_bio_create();

  PKCS12_unpack_authsafes(pkcs12);

  dump_certs_keys_p12(aTHX_ bio, pkcs12, pwd, strlen(pwd), NOCERTS, NULL, NULL);

  RETVAL = sv_bio_final(bio);

  OUTPUT:
  RETVAL

HV* info_as_hash(pkcs12, pwd = "")
  Crypt::OpenSSL::PKCS12 pkcs12
  char *pwd

  PREINIT:
  BIO *bio;
  STACK_OF(PKCS7) *asafes = NULL;

  CONST_ASN1_INTEGER *tmaciter;
  CONST_X509_ALGOR *macalgid;
  CONST_ASN1_OBJECT *macobj;
  CONST_ASN1_OCTET_STRING *tmac;
  CONST_ASN1_OCTET_STRING *tsalt;

  CODE:
  SV *value;

  RETVAL = newHV();

  bio = sv_bio_create();

  if ((asafes = PKCS12_unpack_authsafes(pkcs12)) == NULL)
        RETVAL = newHV();
  HV * mac = newHV();
  /*asafes = PKCS12_unpack_authsafes(pkcs12); */
#if OPENSSL_VERSION_NUMBER > 0x10100000L
  PKCS12_get0_mac(&tmac, &macalgid, &tsalt, &tmaciter, pkcs12);
  /* current hash algorithms do not use parameters so extract just name,
     in future alg_print() may be needed */
  X509_ALGOR_get0(&macobj, NULL, NULL, macalgid);
  i2a_ASN1_OBJECT(bio, macobj);
  value = sv_bio_final(bio);
  if((hv_store(mac, "digest", strlen("digest"), value, 0)) == NULL)
    croak("unable to add digest to the hash");
#else
  tmaciter = pkcs12->mac->iter;
  tmac = pkcs12->mac;
#endif
  SV * mac_iteration = newSViv (tmaciter != NULL ? ASN1_INTEGER_get(tmaciter) : 1L);

  if((hv_store(mac, "iteration", strlen("iteration"), mac_iteration, 0)) == NULL)
    croak("unable to add iteration to the hash");
  bio = sv_bio_create();
  /* BIO_printf(bio, "MAC length: %ld, salt length: %ld", */
  SV * mac_len = newSViv(tmac != NULL ? ASN1_STRING_length(tmac) : 0L);
  SV * salt_len = newSViv(tsalt != NULL ? ASN1_STRING_length(tsalt) : 0L);

  if((hv_store(mac, "length", 6, mac_len, 0)) == NULL)
    croak("unable to add length to the hash");

  if((hv_store(mac, "salt_length", strlen("salt_length"), INT2PTR(SV*, salt_len), 0)) == NULL)
    croak("unable to add salt_length to the hash");

  if((hv_store(RETVAL, "mac", strlen("mac"), newRV_inc((SV *) mac), 0)) == NULL)
    croak("unable to add MAC to the hash");

  dump_certs_keys_p12(aTHX_ bio, pkcs12, pwd, strlen(pwd), INFO, NULL, RETVAL);

  SV * end = sv_bio_final(bio);
  if (SvCUR(end) != 0)
    warn("bio from info_as_hash should be zero length - report issue");

  sv_2mortal((SV*)RETVAL);

  OUTPUT:
  RETVAL

SV*
info(pkcs12, pwd = "")
  Crypt::OpenSSL::PKCS12 pkcs12
  char *pwd

  PREINIT:
  BIO *bio;
  STACK_OF(PKCS7) *asafes = NULL;

  CONST_ASN1_INTEGER *tmaciter;
  CONST_X509_ALGOR *macalgid;
  CONST_ASN1_OBJECT *macobj;
  CONST_ASN1_OCTET_STRING *tmac;
  CONST_ASN1_OCTET_STRING *tsalt;

  CODE:

  bio = sv_bio_create();

  if ((asafes = PKCS12_unpack_authsafes(pkcs12)) == NULL)
        RETVAL = newSVpvn("",0);
#if OPENSSL_VERSION_NUMBER > 0x10100000L
  PKCS12_get0_mac(&tmac, &macalgid, &tsalt, &tmaciter, pkcs12);
  /* current hash algorithms do not use parameters so extract just name,
     in future alg_print() may be needed */
  //X509_ALGOR_get0(&macobj, NULL, NULL, macalgid);
  //i2a_ASN1_OBJECT(bio, macobj);
  X509_ALGOR_get0(&macobj, NULL, NULL, macalgid);
  BIO_puts(bio, "MAC: ");
  i2a_ASN1_OBJECT(bio, macobj);
#else
  tmaciter = pkcs12->mac->iter;
  tmac = pkcs12->mac;
#endif
  /* current hash algorithms do not use parameters so extract just name,
     in future alg_print() may be needed */
#if OPENSSL_VERSION_NUMBER > 0x10100000L
  BIO_printf(bio, ", Iteration %ld\n",
        tmaciter != NULL ? ASN1_INTEGER_get(tmaciter) : 1L);
  BIO_printf(bio, "MAC length: %ld, salt length: %ld\n",
        tmac != NULL ? ASN1_STRING_length(tmac) : 0L,
        tsalt != NULL ? ASN1_STRING_length(tsalt) : 0L);
#else
  BIO_printf(bio, "MAC Iteration %ld\n",
        tmaciter != NULL ? ASN1_INTEGER_get(tmaciter) : 1L);
  /* If we enter empty password try no password first */
  int cpass = 0;
  int twopass = 0;
  if (!pwd[0] && PKCS12_verify_mac(pkcs12, NULL, 0)) {
    /* If mac and crypto pass the same set it to NULL too */
    if (!twopass)
      cpass = NULL;
  } else if (!PKCS12_verify_mac(pkcs12, pwd, -1)) {
    BIO_printf(bio, "Mac verify error: invalid password?\n");
    ERR_print_errors(bio);
    goto end;
  }
  BIO_printf(bio, "MAC verified OK\n");
#endif
  end:
  dump_certs_keys_p12(aTHX_ bio, pkcs12, pwd, strlen(pwd), INFO, NULL, NULL);

  RETVAL = sv_bio_final(bio);

  OUTPUT:
  RETVAL
