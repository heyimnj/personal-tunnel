# Personal Tunnel

Private build repository for the locally modified iOS VPN client.

`personal-tunnel-source.bundle` contains the complete modified source and Git history, not an unmodified upstream import.

Source commit: `e7eb71ec1103cde42a8ebe0ea201f84cac3bef1e`
Bundle SHA-256: `da168b5a8d5c731bf42b70474e435cff9fae039f9f8ee5fed759b342a47af6d6`

Recover a normal source checkout:

```sh
git clone --branch audit/independent-client personal-tunnel-source.bundle source
cd source
git submodule update --init --recursive
```

The build workflow verifies the bundle hash and exact source commit before compiling. No signing credentials or server credentials are uploaded. The resulting IPA is unsigned and requires valid app/Network Extension signing before installation. See REPORT.md inside the source checkout for unresolved verification items.
