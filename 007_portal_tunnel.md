# Foundry portal access via jumpbox SOCKS tunnel

The agent Foundry account has `publicNetworkAccess=Disabled`. The portal at
`ai.azure.com` is public, but its JS makes browser-side calls to
`<account>.services.ai.azure.com`, which only resolves correctly from inside
the agent VNet (private DNS → private endpoint IP).

Routing your **browser** through the jumpbox VM via SOCKS5-over-SSH-over-Bastion
makes the portal work end-to-end without changing system network settings.

## Prerequisites

- `az login` against the right subscription/tenant.
- `azd env select fdev` (the env that holds the deployed jumpbox values).
- Local SSH private key matching `JUMPBOX_SSH_PUBLIC_KEY` — default location
  `~/.ssh/mreg-jumpbox`.
- Bastion in this deployment is **Standard SKU with tunneling enabled** and the
  VM admin user is `azureuser` (key-only SSH).

## One-time: capture the targets

```bash
SUB=$(az account show --query id -o tsv)
RG=mreg-fdev-agent-chn-rg          # azd output: jumpboxBastionResourceGroup
BASTION=mreg-fdev-bastion-chn      # azd output: jumpboxBastionName
VM_ID="/subscriptions/${SUB}/resourceGroups/${RG}/providers/Microsoft.Compute/virtualMachines/mreg-fdev-jb-chn"
```

Or pull them dynamically:

```bash
eval "$(azd env get-values | grep -E '^(jumpboxBastionName|jumpboxBastionResourceGroup|jumpboxVmId)=')"
```

## Step 1 — open the Bastion → port-22 tunnel (Terminal A, keep running)

```bash
az network bastion tunnel \
  --resource-group "$jumpboxBastionResourceGroup" \
  --name           "$jumpboxBastionName" \
  --target-resource-id "$jumpboxVmId" \
  --resource-port 22 --port 2222
```

Expect: `Opening tunnel on port: 2222` then `Tunnel is ready`. Leave it open.

## Step 2 — open the SOCKS5 proxy (Terminal B, keep running)

```bash
ssh -N -D 1080 -p 2222 \
    -o StrictHostKeyChecking=accept-new \
    -i ~/.ssh/mreg-jumpbox \
    azureuser@127.0.0.1
```

- `-N`  — no remote shell, port-forwarding only.
- `-D 1080` — dynamic SOCKS5 proxy on `localhost:1080`.

No output on success — it just sits there.

## Step 3 — point your browser at `socks5://127.0.0.1:1080`

### Option A: Firefox (recommended — per-browser proxy, no system impact)

`Settings` → `Network Settings` → `Manual proxy configuration`:

| Field                              | Value             |
|------------------------------------|-------------------|
| SOCKS Host                         | `127.0.0.1`       |
| Port                               | `1080`            |
| Protocol                           | `SOCKS v5`        |
| ☑ Proxy DNS when using SOCKS v5    | **REQUIRED**      |

The DNS checkbox is the critical bit — it makes Firefox resolve hostnames
through the VM (which uses the VNet-linked private DNS zones) instead of locally.

Navigate to `https://ai.azure.com`. Sign in. Open project `agent-project` under
account `mregfdevfdrychnl33kar`. The "Private network access required" screen
should be gone.

### Option B: Chrome / Edge (isolated profile, single command)

```bash
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --user-data-dir=/tmp/mreg-foundry-profile \
  --proxy-server="socks5://127.0.0.1:1080" \
  --host-resolver-rules="MAP * ~NOTFOUND , EXCLUDE 127.0.0.1" \
  https://ai.azure.com
```

Edge: replace the binary path with
`/Applications/Microsoft\ Edge.app/Contents/MacOS/Microsoft\ Edge`.

The `--host-resolver-rules` flag forces all DNS through the SOCKS proxy
(Chrome's default is to resolve locally even with SOCKS5).

## Verify the tunnel is doing what you think

From inside the VM (Bastion shell or via the SSH tunnel) and from your
**browser's network tab**, the project FQDN must resolve to a 192.168.x.x
private endpoint IP, not a public one:

```bash
# from your laptop, over the SOCKS proxy:
curl -x socks5h://127.0.0.1:1080 -sI https://mregfdevfdrychnl33kar.services.ai.azure.com/ | head -1
# expect: HTTP/2 401  (auth required, but routed — *not* a TLS/connection error)

# DNS check via the VM resolver:
curl -x socks5h://127.0.0.1:1080 -s https://mregfdevfdrychnl33kar.services.ai.azure.com/ -o /dev/null -w '%{remote_ip}\n'
# expect a 192.168.x.x address
```

`socks5h://` (not `socks5://`) is the curl idiom that delegates DNS to the
proxy — same semantics as Firefox's "Proxy DNS" checkbox.

## Teardown

Ctrl-C both terminals. Reset Firefox proxy to `No proxy` or close the Chrome
isolated profile.

## Troubleshooting

| Symptom                                    | Cause                                                       |
|--------------------------------------------|-------------------------------------------------------------|
| `Permission denied (publickey)` on Step 2  | Wrong private key path / wrong file permissions (`chmod 600`). |
| Portal still shows "private network required" | Firefox "Proxy DNS" checkbox is OFF — browser resolved the FQDN locally to a public IP. |
| Tunnel opens but `ssh` hangs               | Bastion `tunnel` command not actually ready yet — wait for `Tunnel is ready` line. |
| `az network bastion tunnel` fails with `not supported on sku` | Bastion is on `Basic` tier. This deploy uses `Standard`; if regenerated, ensure `sku.name=Standard` and `enableTunneling=true`. |
| Cross-region portal pages load slowly      | Expected — every request hairpins LAN → Bastion → VM → Azure backbone. |

## Why this works (one-paragraph version)

The VM lives in the agent VNet, which is linked to the private DNS zones for
`privatelink.services.ai.azure.com`, `privatelink.cognitiveservices.azure.com`,
etc. When your browser asks the SOCKS5 proxy to resolve
`<account>.services.ai.azure.com`, the VM's resolver answers with the private
endpoint IP. The SOCKS proxy then opens a TCP connection from inside the VNet
to that PE, and the PE accepts the call (because `publicNetworkAccess=Disabled`
allows only PE traffic). From the portal's perspective, your browser appears
to be a tenant of the agent VNet.
