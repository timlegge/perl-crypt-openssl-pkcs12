use strict;
use warnings;
use Test::More;
use Digest::SHA qw/sha256_hex/;

BEGIN { use_ok('Crypt::OpenSSL::PKCS12') };

my $openssl_output =<< 'OPENSSL_END';
MAC: sha1, Iteration 2048
MAC length: 20, salt length: 8
PKCS7 Encrypted data: pbeWithSHA1And40BitRC2-CBC, Iteration 2048
Certificate bag
Bag Attributes
    localKeyID: CD 93 42 14 8F 01 1B D4 CB C7 11 42 E7 32 15 DE 17 DE 39 07 
    friendlyName: Test PKCS12
subject=C = US, ST = California, O = ElectricRain, CN = test.electricrain.com
issuer=C = US, ST = California, L = Daly City, O = ElectricRain, CN = test.electricrain.com
-----BEGIN CERTIFICATE-----
MIICuTCCAiKgAwIBAgIDEAABMA0GCSqGSIb3DQEBBQUAMG0xCzAJBgNVBAYTAlVT
MRMwEQYDVQQIEwpDYWxpZm9ybmlhMRIwEAYDVQQHEwlEYWx5IENpdHkxFTATBgNV
BAoTDEVsZWN0cmljUmFpbjEeMBwGA1UEAxMVdGVzdC5lbGVjdHJpY3JhaW4uY29t
MB4XDTA3MDEwNDAyMTMyOFoXDTM0MDUyMTAyMTMyOFowWTELMAkGA1UEBhMCVVMx
EzARBgNVBAgTCkNhbGlmb3JuaWExFTATBgNVBAoTDEVsZWN0cmljUmFpbjEeMBwG
A1UEAxMVdGVzdC5lbGVjdHJpY3JhaW4uY29tMIGfMA0GCSqGSIb3DQEBAQUAA4GN
ADCBiQKBgQCpSKQfz95JoZaTUrp4Ewu9/9D2h+ql1EjQiO5YV9MKfybUIolejhH6
ZWcV1+ni+qA2saro1qYTxPumQjJRgGIfXuR1aGCfI5emT3PlAtiEpEmZnfKlyIzi
MNeqvztDBHiB6YGlqRdVCGsq5lkXb2+KjXCBFl47pLoUB6rnuEz+dwIDAQABo3sw
eTAJBgNVHRMEAjAAMCwGCWCGSAGG+EIBDQQfFh1PcGVuU1NMIEdlbmVyYXRlZCBD
ZXJ0aWZpY2F0ZTAdBgNVHQ4EFgQU6XpmiGyk7ewEp1G89WIxkwLFOWUwHwYDVR0j
BBgwFoAUfY6WdDrwkUvZeC8H1IMGFAr43vAwDQYJKoZIhvcNAQEFBQADgYEAiuXN
biBHOjMjCbm5UQTyS/ORyAzy7jD883fXaovW7ammeBw/O1Zi1+FiuwvUDPFb2oYo
ME/zei4ptARlhvXl+yXSohPWorVB6tC7qGwdGVSnFS85pmzt0ZiWS6bfHjYIY7Xc
cd3gIHPrq37UQo4eyUo7Rg1IHPnfCYT0p8jYKhA=
-----END CERTIFICATE-----
Certificate bag
Bag Attributes: <No Attributes>
subject=C = US, ST = California, L = Daly City, O = ElectricRain, CN = test.electricrain.com
issuer=C = US, ST = California, L = Daly City, O = ElectricRain, CN = test.electricrain.com
-----BEGIN CERTIFICATE-----
MIIDKzCCApSgAwIBAgIJANl4vnVWcooUMA0GCSqGSIb3DQEBBQUAMG0xCzAJBgNV
BAYTAlVTMRMwEQYDVQQIEwpDYWxpZm9ybmlhMRIwEAYDVQQHEwlEYWx5IENpdHkx
FTATBgNVBAoTDEVsZWN0cmljUmFpbjEeMBwGA1UEAxMVdGVzdC5lbGVjdHJpY3Jh
aW4uY29tMB4XDTA3MDEwNDAyMTIwM1oXDTA4MDEwNDAyMTIwM1owbTELMAkGA1UE
BhMCVVMxEzARBgNVBAgTCkNhbGlmb3JuaWExEjAQBgNVBAcTCURhbHkgQ2l0eTEV
MBMGA1UEChMMRWxlY3RyaWNSYWluMR4wHAYDVQQDExV0ZXN0LmVsZWN0cmljcmFp
bi5jb20wgZ8wDQYJKoZIhvcNAQEBBQADgY0AMIGJAoGBAO3yh8iE6lDfPrn9auet
0zaum4Jg/qrCZUcGqtt3jUjtx28ajQ0WcpOIwJmhGCijHM7Gy2q3Zfgk+t3z2ka7
8IxHW1a8g04N0EBbh6LKBs71gn9srGliTox1NZNe2BrfAWKOAe+sx+upNJ2JbGUA
SiKoNa6LjhDwaYjC4wU54NflAgMBAAGjgdIwgc8wHQYDVR0OBBYEFH2OlnQ68JFL
2XgvB9SDBhQK+N7wMIGfBgNVHSMEgZcwgZSAFH2OlnQ68JFL2XgvB9SDBhQK+N7w
oXGkbzBtMQswCQYDVQQGEwJVUzETMBEGA1UECBMKQ2FsaWZvcm5pYTESMBAGA1UE
BxMJRGFseSBDaXR5MRUwEwYDVQQKEwxFbGVjdHJpY1JhaW4xHjAcBgNVBAMTFXRl
c3QuZWxlY3RyaWNyYWluLmNvbYIJANl4vnVWcooUMAwGA1UdEwQFMAMBAf8wDQYJ
KoZIhvcNAQEFBQADgYEAVDpsT0lKnMG+49Y8owI+G7RoHRt/dp0oc2VPba1GEOt/
T7/i5cqOfVEVMS9LThSKmzWtBJYhePXo8XPHvpeDKqVgOIxauZS6bztr91pszQui
R5mk1sAPWWaKOTCDkrwQ0lKBEZjyLSGSPlB+GEPlxtwwfyisu6Nw8OJ7LjrOLN4=
-----END CERTIFICATE-----
PKCS7 Data
Shrouded Keybag: pbeWithSHA1And3-KeyTripleDES-CBC, Iteration 2048
Bag Attributes
    localKeyID: CD 93 42 14 8F 01 1B D4 CB C7 11 42 E7 32 15 DE 17 DE 39 07 
    friendlyName: Test PKCS12
Key Attributes: <No Attributes>
-----BEGIN PRIVATE KEY-----
MIICdwIBADANBgkqhkiG9w0BAQEFAASCAmEwggJdAgEAAoGBAKlIpB/P3kmhlpNS
ungTC73/0PaH6qXUSNCI7lhX0wp/JtQiiV6OEfplZxXX6eL6oDaxqujWphPE+6ZC
MlGAYh9e5HVoYJ8jl6ZPc+UC2ISkSZmd8qXIjOIw16q/O0MEeIHpgaWpF1UIayrm
WRdvb4qNcIEWXjukuhQHque4TP53AgMBAAECgYEAiWwQ4EpM95UXuY0FFwjPFXSg
XCHGGMyWN8ORSWIyTmkeSkOnJH1MlurOnmri0YIHoZ7lUZM+yvm0GCnQ01zXSbHz
SqIWEZgXsXoMc+dCxDMLtNKMHYyvEUK5Q14dmnfn8sMW6Igv3ZFUFK/g0F0Eu6rd
KBgK9Jj2IgBGNEGe62ECQQDYDvtQSzH595EXFwHC1GDmmLjnQBOHg+oBP8UPBZTc
HlUPI36CBIoHbZRM/l2Zg4sbAXJkGdBmQR3wJdn7x8/fAkEAyJQIcPIPlLsbuh6X
/n6rz7T6ZellpPR2Li0XzUmvZsUBMeWbupVjQ6fXTxmwE/he4KZq/dFfyFkD/wRO
Jg7EaQJABKvmQSkvDnGM4IvtzNGcur+ol89p3K88ewRu9VEwk8XQHwCsdpE0js6O
u09wpKYUduQEHif0upFD3XJkES6TzwJADA76QvAKh8KH9DSKpr4uzhnvQ9k4RyZ7
RGNpnunjJaaKX9mR9zGr+hFJHHRK5ah068SVghToUT8owlgb6qXQoQJBAKG7DquK
edjrMOH641LwWMcQSK3FhAQbt4qUUytEdSEYTy4ObpScWrxEt67lcWu4yIJxu7e4
0HErfonOx1g+Ox0=
-----END PRIVATE KEY-----
OPENSSL_END

my $pass   = "testing";
#my $pkcs12 = Crypt::OpenSSL::PKCS12->new_from_file('certs/test.p12');
my $pkcs12 = Crypt::OpenSSL::PKCS12->new_from_file('certs/test_le_1.1.p12');

my $certificate = $pkcs12->certificate($pass);

my $info = $pkcs12->info($pass);

ok(sha256_hex($info) eq sha256_hex($openssl_output), "Output matches OpenSSL");

done_testing;
