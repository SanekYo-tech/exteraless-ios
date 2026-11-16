# iOS DNS-SD linkage correction

Full build43776035926/54b2f7e8 compiled the Swift client, then the MtProtoKit
framework linker failed with `ld: library 'dns_sd' not found`.

`MtProtoKit/BUILD` now relies on the standard libSystem umbrella for the public
DNSService API, removing its explicit standalone `libdns_sd` dependency. The
resolver still calls `DNSServiceQueryRecord`, `DNSServiceSetDispatchQueue` and
`DNSServiceRefDeallocate` through the public `dns_sd.h` declarations.

Supporting SDK reference: the iPhoneOS18.0 `libSystem.B.tbd` exports the three
symbols through its embedded `libsystem_dnssd` re-export section:
https://github.com/xybp888/iOS-SDKs/blob/master/iPhoneOS18.0.sdk/usr/lib/libSystem.B.tbd.
This historical SDK reference is not a current-Xcode link pass. The next complete
Xcode27.1 app build must validate the corrected linkage.
