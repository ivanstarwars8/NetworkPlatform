#!/usr/bin/env python3
"""Small App Store Connect API client for the TestFlight workflow (.github/workflows/testflight.yml).

Standard library + the `openssl` binary only (ES256 JWT signed by `openssl dgst`). Credentials come from the
environment and are never printed:
    ASC_KEY_ID, ASC_ISSUER_ID   key identifier and issuer
    ASC_KEY_PATH                path of the .p8 private key (written by the workflow into a temporary directory)

Commands (all print only non-secret metadata):
    preflight   --app ID --bundle-id ID --version V --build N
                Read-only. Checks the app record's bundle id, lists App Store versions and TestFlight trains, refuses a
                build number that already exists and a marketing version not higher than an approved one.
    profiles    --cert-serial HEX --bundle-id ID [--bundle-id ID ...] --out DIR
                Finds (or creates) one active IOS_APP_STORE profile per bundle id that contains the distribution
                certificate with that serial number. Writes DIR/<bundle-id>.mobileprovision and prints
                "<bundle-id> <profile name>" lines. Creating a profile is the only write this command does.
    wait-build  --app ID --version V --build N [--timeout SECONDS]
                Read-only. Polls until the uploaded build exists and its processingState is VALID; prints its id.
    beta-group  --app ID --build-id ID --group NAME
                Checks that NAME is an internal group of the app; if it does not already receive every build
                (hasAccessToAllBuilds), adds the build to it. Refuses external groups.
"""
import argparse
import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.appstoreconnect.apple.com"


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def der_to_raw(sig):
    """ECDSA-Sig-Value (DER SEQUENCE of two INTEGERs) -> r||s, 32 bytes each (JWS ES256)."""
    def read_int(buf, i):
        if buf[i] != 0x02:
            raise ValueError("bad DER signature")
        n = buf[i + 1]
        v = buf[i + 2:i + 2 + n].lstrip(b"\x00")
        return v.rjust(32, b"\x00"), i + 2 + n
    if sig[0] != 0x30:
        raise ValueError("bad DER signature")
    i = 3 if sig[1] & 0x80 else 2
    r, i = read_int(sig, i)
    s, _ = read_int(sig, i)
    return r + s


_token = {"value": None, "exp": 0}


def token():
    now = int(time.time())
    if _token["value"] and now < _token["exp"] - 60:
        return _token["value"]
    key_id, issuer, key_path = os.environ["ASC_KEY_ID"], os.environ["ASC_ISSUER_ID"], os.environ["ASC_KEY_PATH"]
    header = b64url(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}).encode())
    exp = now + 15 * 60
    payload = b64url(json.dumps({"iss": issuer, "iat": now, "exp": exp, "aud": "appstoreconnect-v1"}).encode())
    signing_input = f"{header}.{payload}".encode()
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key_path], input=signing_input,
                         capture_output=True, check=True).stdout
    _token["value"] = f"{header}.{payload}.{b64url(der_to_raw(der))}"
    _token["exp"] = exp
    return _token["value"]


def call(method, path, params=None, body=None):
    url = path if path.startswith("http") else API + path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "Bearer " + token())
    if data is not None:
        req.add_header("Content-Type", "application/json")
    for attempt in range(5):
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                raw = resp.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors="replace")
            if e.code in (429, 500, 502, 503, 504) and attempt < 4:
                time.sleep(5 * (attempt + 1))
                continue
            sys.exit(f"ASC API {method} {path} -> HTTP {e.code}: {detail[:1500]}")
        except urllib.error.URLError as e:
            if attempt < 4:
                time.sleep(5 * (attempt + 1))
                continue
            sys.exit(f"ASC API {method} {path} -> {e}")


def get_all(path, params=None, limit=200):
    """GET with pagination. Some related-resource endpoints refuse `limit`; pass limit=None for them."""
    out, included = [], []
    doc = call("GET", path, dict(params or {}, **({"limit": limit} if limit else {})))
    while True:
        out += doc.get("data", [])
        included += doc.get("included", [])
        nxt = doc.get("links", {}).get("next")
        if not nxt:
            return out, included
        doc = call("GET", nxt)


def version_tuple(v):
    return tuple(int(p) if p.isdigit() else 0 for p in v.split("."))


APPROVED_STATES = {
    "READY_FOR_SALE", "READY_FOR_DISTRIBUTION", "REPLACED_WITH_NEW_VERSION", "PENDING_DEVELOPER_RELEASE",
    "PENDING_APPLE_RELEASE", "PROCESSING_FOR_APP_STORE", "PROCESSING_FOR_DISTRIBUTION", "REMOVED_FROM_SALE",
    "DEVELOPER_REMOVED_FROM_SALE", "ACCEPTED",
}


def cmd_preflight(a):
    app = call("GET", f"/v1/apps/{a.app}")["data"]["attributes"]
    print(f"app {a.app}: name={app.get('name')!r} bundleId={app.get('bundleId')}")
    if app.get("bundleId") != a.bundle_id:
        sys.exit(f"error: app {a.app} has bundle id {app.get('bundleId')}, expected {a.bundle_id}")
    versions, _ = get_all(f"/v1/apps/{a.app}/appStoreVersions", {"fields[appStoreVersions]": "versionString,appStoreState,platform"})
    approved = []
    for v in versions:
        at = v["attributes"]
        print(f"  App Store version {at.get('versionString')} {at.get('platform')} {at.get('appStoreState')}")
        if at.get("appStoreState") in APPROVED_STATES:
            approved.append(at.get("versionString"))
    trains, _ = get_all(f"/v1/apps/{a.app}/preReleaseVersions", {"fields[preReleaseVersions]": "version,platform"})
    for t in trains:
        print(f"  TestFlight train {t['attributes'].get('version')} {t['attributes'].get('platform')}")
    builds, _ = get_all("/v1/builds", {"filter[app]": a.app, "fields[builds]": "version,processingState,uploadedDate"})
    numbers = sorted({int(b["attributes"]["version"]) for b in builds if b["attributes"]["version"].isdigit()})
    print(f"  existing build numbers: {numbers}")
    if a.build in numbers:
        sys.exit(f"error: build number {a.build} already exists in app {a.app}")
    if numbers and a.build <= max(numbers):
        sys.exit(f"error: build number {a.build} is not higher than the highest existing {max(numbers)}")
    if approved:
        top = max(approved, key=version_tuple)
        if version_tuple(a.version) <= version_tuple(top):
            sys.exit(f"error: marketing version {a.version} must be higher than the approved version {top}")
    print(f"preflight OK: version {a.version} build {a.build}")


def norm_serial(s):
    return s.strip().upper().lstrip("0")


def cmd_profiles(a):
    certs, _ = get_all("/v1/certificates", {"filter[certificateType]": "DISTRIBUTION,IOS_DISTRIBUTION",
                                            "fields[certificates]": "serialNumber,certificateType,displayName,expirationDate"})
    cert = next((c for c in certs if norm_serial(c["attributes"]["serialNumber"]) == norm_serial(a.cert_serial)), None)
    if not cert:
        sys.exit("error: the distribution certificate of DISTRIBUTION_P12_BASE64 is not in this team's certificate list")
    print(f"certificate: {cert['attributes'].get('certificateType')} expires {cert['attributes'].get('expirationDate')}")
    os.makedirs(a.out, exist_ok=True)
    for bundle in a.bundle_id:
        ids, _ = get_all("/v1/bundleIds", {"filter[identifier]": bundle, "filter[platform]": "IOS"})
        bid = next((b for b in ids if b["attributes"]["identifier"] == bundle), None)
        if not bid:
            sys.exit(f"error: bundle id {bundle} is not registered for iOS in this team")
        caps, _ = get_all(f"/v1/bundleIds/{bid['id']}/bundleIdCapabilities", limit=None)
        print(f"{bundle}: capabilities {sorted(c['attributes'].get('capabilityType') for c in caps)}")
        base_name = f"NetworkPlatform CI AppStore {bundle}"
        profs, _ = get_all(f"/v1/bundleIds/{bid['id']}/profiles", {"fields[profiles]": "name,profileType,profileState,uuid,expirationDate"}, limit=None)
        chosen = None
        for p in profs:
            at = p["attributes"]
            if not at["name"].startswith(base_name) or at["profileType"] != "IOS_APP_STORE" or at["profileState"] != "ACTIVE":
                continue
            pc, _ = get_all(f"/v1/profiles/{p['id']}/certificates", {"fields[certificates]": "serialNumber"}, limit=None)
            if any(c["id"] == cert["id"] for c in pc):
                chosen = p
                break
        if chosen:
            print(f"{bundle}: reusing profile {chosen['attributes']['name']!r}")
        else:
            name = f"{base_name} {time.strftime('%Y%m%d%H%M%S', time.gmtime())}"
            chosen = call("POST", "/v1/profiles", body={"data": {
                "type": "profiles",
                "attributes": {"name": name, "profileType": "IOS_APP_STORE"},
                "relationships": {
                    "bundleId": {"data": {"type": "bundleIds", "id": bid["id"]}},
                    "certificates": {"data": [{"type": "certificates", "id": cert["id"]}]},
                },
            }})["data"]
            print(f"{bundle}: created profile {name!r}")
        full = call("GET", f"/v1/profiles/{chosen['id']}")["data"]["attributes"]
        with open(os.path.join(a.out, f"{bundle}.mobileprovision"), "wb") as f:
            f.write(base64.b64decode(full["profileContent"]))
        print(f"PROFILE {bundle} {full['name']}")


def find_build(a):
    data = call("GET", "/v1/builds", {"filter[app]": a.app, "filter[version]": str(a.build),
                                      "filter[preReleaseVersion.version]": a.version,
                                      "fields[builds]": "version,processingState,uploadedDate,expired"})["data"]
    return data[0] if data else None


def cmd_wait_build(a):
    deadline = time.time() + a.timeout
    last = None
    while time.time() < deadline:
        b = find_build(a)
        state = b["attributes"]["processingState"] if b else "NOT_YET_VISIBLE"
        if state != last:
            print(f"{time.strftime('%H:%M:%S')} build {a.version} ({a.build}): {state}", flush=True)
            last = state
        if state == "VALID":
            print(f"BUILD_ID {b['id']}")
            out = os.environ.get("GITHUB_OUTPUT")
            if out:
                with open(out, "a") as f:
                    f.write(f"build_id={b['id']}\n")
            return
        if state in ("FAILED", "INVALID"):
            sys.exit(f"error: build processing ended in {state}")
        time.sleep(30)
    sys.exit(f"error: build not VALID after {a.timeout} s (last state {last})")


def cmd_beta_group(a):
    groups, _ = get_all(f"/v1/apps/{a.app}/betaGroups", {"fields[betaGroups]": "name,isInternalGroup,hasAccessToAllBuilds"})
    group = next((g for g in groups if g["attributes"]["name"] == a.group), None)
    if not group:
        sys.exit(f"error: no beta group named {a.group!r} in app {a.app}")
    at = group["attributes"]
    print(f"group {a.group!r}: internal={at.get('isInternalGroup')} hasAccessToAllBuilds={at.get('hasAccessToAllBuilds')}")
    if not at.get("isInternalGroup"):
        sys.exit(f"error: {a.group!r} is not an internal group; this workflow never distributes to external groups")
    members, _ = get_all(f"/v1/betaGroups/{group['id']}/builds", {"fields[builds]": "version"})
    if any(m["id"] == a.build_id for m in members):
        print("build is already in the group")
        return
    if at.get("hasAccessToAllBuilds"):
        print("the group receives every build automatically; nothing to add")
        return
    call("POST", f"/v1/betaGroups/{group['id']}/relationships/builds", body={"data": [{"type": "builds", "id": a.build_id}]})
    print("build added to the group")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("preflight")
    s.add_argument("--app", required=True); s.add_argument("--bundle-id", required=True)
    s.add_argument("--version", required=True); s.add_argument("--build", type=int, required=True)
    s = sub.add_parser("profiles")
    s.add_argument("--cert-serial", required=True); s.add_argument("--bundle-id", action="append", required=True)
    s.add_argument("--out", required=True)
    s = sub.add_parser("wait-build")
    s.add_argument("--app", required=True); s.add_argument("--version", required=True)
    s.add_argument("--build", type=int, required=True); s.add_argument("--timeout", type=int, default=3600)
    s = sub.add_parser("beta-group")
    s.add_argument("--app", required=True); s.add_argument("--build-id", required=True); s.add_argument("--group", required=True)
    a = p.parse_args()
    {"preflight": cmd_preflight, "profiles": cmd_profiles, "wait-build": cmd_wait_build, "beta-group": cmd_beta_group}[a.cmd](a)


if __name__ == "__main__":
    main()
