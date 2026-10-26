# Personal Tunnel

Private build repository for the locally modified iOS VPN client.

`personal-tunnel-source.bundle` contains the complete modified source and Git history, not an unmodified upstream import.

Source commit: `3431e76319cb4b2b279c9492ab2bea1ba5d731bb`
Bundle SHA-256: `16418ad304dd37d327582ef282768d2344f7a67d62246bec6a84de5c4faa6953`

Recover a normal source checkout:

```sh
git clone --branch audit/independent-client personal-tunnel-source.bundle source
cd source
git submodule update --init --recursive
```

The build workflow verifies the bundle hash and exact source commit before compiling. No signing credentials or server credentials are uploaded. The resulting IPA is unsigned and requires valid app/Network Extension signing before installation. See REPORT.md inside the source checkout for unresolved verification items.
