# Personal Tunnel

Private build repository for the locally modified iOS VPN client.

`personal-tunnel-source.bundle` contains the complete modified source and Git history, not an unmodified upstream import.

Source commit: `5b41dba9e8e7bbbc607e55e03244db9ed43095a6`
Bundle SHA-256: `04693b26cb41b48d78ad0f20d5d67e30101186e6ec168274c498cb2b8a068a36`

Recover a normal source checkout:

```sh
git clone --branch audit/independent-client personal-tunnel-source.bundle source
cd source
git submodule update --init --recursive
```

The build workflow verifies the bundle hash and exact source commit before compiling. No signing credentials or server credentials are uploaded. The resulting IPA is unsigned and requires valid app/Network Extension signing before installation. See REPORT.md inside the source checkout for unresolved verification items.
