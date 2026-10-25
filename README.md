# Personal Tunnel

Private build repository for the locally modified iOS VPN client.

`personal-tunnel-source.bundle` contains the complete modified source and Git history, not an unmodified upstream import.

Source commit: `54cf6084c55930c3be46b20e60343329bb8c6250`
Bundle SHA-256: `3c0a32f172c7ab5e29552b0fd55d07afee3c909da66bdff6e76c9c095131fef6`

Recover a normal source checkout:

```sh
git clone --branch audit/independent-client personal-tunnel-source.bundle source
cd source
git submodule update --init --recursive
```

The build workflow verifies the bundle hash and exact source commit before compiling. No signing credentials or server credentials are uploaded. The resulting IPA is unsigned and requires valid app/Network Extension signing before installation. See REPORT.md inside the source checkout for unresolved verification items.
