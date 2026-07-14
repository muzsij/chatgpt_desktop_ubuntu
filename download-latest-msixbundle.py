#!/usr/bin/env python3
"""Download the latest official ChatGPT Desktop .msixbundle from Microsoft.

This talks to Microsoft's own Store delivery backend (displaycatalog + the FE3
Windows Update SOAP service), the same path the store.rg-adguard.net generator
uses server-side. Nothing is scraped from a Cloudflare-protected page, and the
package is fetched straight from Microsoft's delivery CDN.

Typical use (drops the bundle next to this script so the build can pick it up):

    ./download-latest-msixbundle.py
    ./build-chatgpt-native-deb.sh --exe ./OpenAI.ChatGPT-Desktop_<version>.Msixbundle
"""
from __future__ import annotations

import argparse
import html
import os
import re
import ssl
import sys
import urllib.request

# Microsoft Store product id for the ChatGPT desktop app (OpenAI.ChatGPT-Desktop).
PRODUCT_ID_DEFAULT = "9nt1r1c2hh7j"

DISPLAYCATALOG = ("https://displaycatalog.mp.microsoft.com/v7.0/products/"
                  "{pid}?languages=en-US&market=US")
FE3 = "https://fe3.delivery.mp.microsoft.com/ClientWebService/client.asmx"
FE3_SECURED = FE3 + "/secured"

SOAP_UA = "Windows-Update-Agent/10.0.10011.16384 Client-Protocol/2.31"
DL_UA = "Microsoft-Delivery-Optimization/10.1"

# Baseline "already installed" non-leaf update ids the WU client always sends.
BASE_NONLEAF = [1, 2, 3, 11, 19, 2359974, 5169044, 8788830, 23110993, 23110994,
                59830006, 59830007, 59830008, 60484010, 62450018, 62450019, 62450020]

_ctx = ssl.create_default_context()


def _die(msg: str) -> "None":
    sys.stderr.write(f"\033[1;31merror:\033[0m {msg}\n")
    raise SystemExit(1)


def _section(msg: str) -> None:
    sys.stderr.write(f"\n\033[1;36m== {msg} ==\033[0m\n")


# --------------------------------------------------------------------------- #
# SOAP plumbing
# --------------------------------------------------------------------------- #
def _post_soap(url: str, body: str) -> str:
    req = urllib.request.Request(
        url,
        data=body.encode("utf-8"),
        headers={"Content-Type": "application/soap+xml; charset=utf-8",
                 "User-Agent": SOAP_UA},
    )
    with urllib.request.urlopen(req, context=_ctx, timeout=60) as r:
        return r.read().decode("utf-8", "replace")


_WU_TICKET = (
    '<wuws:WindowsUpdateTicketsToken wsu:id="ClientMSA" '
    'xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd" '
    'xmlns:wuws="http://schemas.microsoft.com/msus/2014/10/WindowsUpdateAuthorization">'
    '<TicketType Name="AAD" Version="1.0" Policy="MBI_SSL"></TicketType>'
    '</wuws:WindowsUpdateTicketsToken>'
)


def _header(action: str, to: str) -> str:
    return (
        '<s:Header>'
        f'<a:Action s:mustUnderstand="1">{action}</a:Action>'
        '<a:MessageID>urn:uuid:5754a03d-d8d5-489f-b24d-18509194001b</a:MessageID>'
        f'<a:To s:mustUnderstand="1">{to}</a:To>'
        '<o:Security s:mustUnderstand="1" '
        'xmlns:o="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd">'
        '<Timestamp xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">'
        '<Created>2017-12-02T00:00:00.000Z</Created><Expires>2100-12-02T00:00:00.000Z</Expires></Timestamp>'
        + _WU_TICKET +
        '</o:Security></s:Header>'
    )


_ACTION = "http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService/{}"
_WS = "http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService"


def get_wu_category_id(pid: str) -> str:
    import json
    url = DISPLAYCATALOG.format(pid=pid)
    with urllib.request.urlopen(url, context=_ctx, timeout=60) as r:
        data = json.load(r)
    product = data.get("Product") or {}
    for sku in product.get("DisplaySkuAvailabilities", []):
        fd = sku.get("Sku", {}).get("Properties", {}).get("FulfillmentData", {})
        if fd.get("WuCategoryId"):
            pfn = fd.get("PackageFamilyName", "")
            prefix = pfn.rsplit("_", 1)[0] if "_" in pfn else pfn
            return fd["WuCategoryId"], prefix
    _die(f"no WuCategoryId in displaycatalog response for product {pid}")


def get_cookie() -> str:
    action = _ACTION.format("GetCookie")
    body = (
        '<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" '
        'xmlns:a="http://www.w3.org/2005/08/addressing">'
        + _header(action, FE3) +
        f'<s:Body><GetCookie xmlns="{_WS}">'
        '<oldCookie><Expiration>2017-01-01T00:00:00Z</Expiration></oldCookie>'
        '<lastChange>2015-10-21T17:01:07.1472913Z</lastChange>'
        '<currentTime>2017-12-02T00:00:00.000Z</currentTime>'
        '<protocolVersion>1.40</protocolVersion>'
        '</GetCookie></s:Body></s:Envelope>'
    )
    resp = _post_soap(FE3, body)
    m = re.search(r"<EncryptedData>(.+?)</EncryptedData>", resp, re.S)
    if not m:
        _die("GetCookie failed (no EncryptedData in response)")
    return m.group(1)


def _sync_body(cookie: str, cat_id: str, nonleaf_ids: list) -> str:
    action = _ACTION.format("SyncUpdates")
    ints = "".join(f"<int>{i}</int>" for i in nonleaf_ids)
    return (
        '<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" '
        'xmlns:a="http://www.w3.org/2005/08/addressing">'
        + _header(action, FE3) +
        f'<s:Body><SyncUpdates xmlns="{_WS}">'
        f'<cookie><Expiration>2100-01-01T00:00:00Z</Expiration>'
        f'<EncryptedData>{cookie}</EncryptedData></cookie>'
        '<parameters><ExpressQuery>false</ExpressQuery>'
        f'<InstalledNonLeafUpdateIDs>{ints}</InstalledNonLeafUpdateIDs>'
        '<OtherCachedUpdateIDs></OtherCachedUpdateIDs>'
        '<SkipSoftwareSync>false</SkipSoftwareSync>'
        '<NeedTwoGroupOutOfScopeUpdates>true</NeedTwoGroupOutOfScopeUpdates>'
        f'<FilterAppCategoryIds><CategoryIdentifier><Id>{cat_id}</Id>'
        '</CategoryIdentifier></FilterAppCategoryIds>'
        '<AlsoPerformRegularSync>false</AlsoPerformRegularSync><ComputerSpec/>'
        '<ExtendedUpdateInfoParameters><XmlUpdateFragmentTypes>'
        '<XmlUpdateFragmentType>Extended</XmlUpdateFragmentType>'
        '<XmlUpdateFragmentType>Published</XmlUpdateFragmentType>'
        '<XmlUpdateFragmentType>Core</XmlUpdateFragmentType></XmlUpdateFragmentTypes>'
        '<Locales><string>en-US</string><string>en</string></Locales>'
        '</ExtendedUpdateInfoParameters>'
        '<ClientPreferredLanguages><string>en-US</string></ClientPreferredLanguages>'
        '<ProductsParameters><SyncCurrentVersionOnly>false</SyncCurrentVersionOnly>'
        '<DeviceAttributes>E:BranchReadinessLevel=CBB&amp;OSVersion=10.0.19041.0&amp;App=WU_STORE</DeviceAttributes>'
        '<CallerAttributes>E:Interactive=1&amp;IsSeeker=1&amp;Acquisition=1&amp;'
        'Id=Acquisition%3BMicrosoft.WindowsStore_8wekyb3d8bbwe</CallerAttributes>'
        '<Products></Products></ProductsParameters>'
        '</parameters></SyncUpdates></s:Body></s:Envelope>'
    )


def sync_updates(cookie: str, cat_id: str) -> str:
    """Two-pass SyncUpdates.

    Pass 1 returns the category/non-leaf detectoid tree; feeding those ids back
    in pass 2 reveals the leaf updates that actually carry the package files.
    """
    r1 = _post_soap(FE3, _sync_body(cookie, cat_id, BASE_NONLEAF))
    pass1_ids = [int(i) for i in re.findall(r"<UpdateInfo><ID>(\d+)</ID>", r1)]
    r2 = _post_soap(FE3, _sync_body(cookie, cat_id, BASE_NONLEAF + pass1_ids))
    return r2


def get_ext_info(cookie: str, update_id: str, revision: str) -> str:
    action = _ACTION.format("GetExtendedUpdateInfo2")
    ids = (f'<UpdateIdentity><UpdateID>{update_id}</UpdateID>'
           f'<RevisionNumber>{revision}</RevisionNumber></UpdateIdentity>')
    body = (
        '<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" '
        'xmlns:a="http://www.w3.org/2005/08/addressing">'
        + _header(action, FE3_SECURED) +
        f'<s:Body><GetExtendedUpdateInfo2 xmlns="{_WS}">'
        f'<updateIDs>{ids}</updateIDs>'
        '<infoTypes><XmlUpdateFragmentType>FileUrl</XmlUpdateFragmentType>'
        '<XmlUpdateFragmentType>FileDecryption</XmlUpdateFragmentType></infoTypes>'
        '<deviceAttributes>E:BranchReadinessLevel=CBB&amp;OSVersion=10.0.19041.0&amp;App=WU_STORE</deviceAttributes>'
        '</GetExtendedUpdateInfo2></s:Body></s:Envelope>'
    )
    return _post_soap(FE3_SECURED, body)


# --------------------------------------------------------------------------- #
# Selection + download
# --------------------------------------------------------------------------- #
def _version_tuple(moniker: str):
    m = re.search(r"_([0-9]+(?:\.[0-9]+)+)_", moniker)
    return tuple(int(x) for x in m.group(1).split(".")) if m else ()


def _version_str(moniker: str) -> str:
    m = re.search(r"_([0-9]+(?:\.[0-9]+)+)_", moniker)
    return m.group(1) if m else "0.0.0"


def pick_bundle(sync_xml: str, pkg_prefix: str):
    """Return (moniker, update_id, revision) for the newest neutral bundle."""
    best = None
    for blk in re.findall(r"<UpdateInfo>.*?</UpdateInfo>", sync_xml, re.S):
        ub = html.unescape(blk)
        ident = re.search(r'<UpdateIdentity UpdateID="([^"]+)" RevisionNumber="([^"]+)"', ub)
        mon = re.search(r'PackageMoniker="([^"]+)"', ub)
        if not (ident and mon):
            continue
        moniker = mon.group(1)
        if not moniker.lower().startswith(pkg_prefix.lower()):
            continue
        if "_neutral_" not in moniker:  # the bundle is the neutral entry
            continue
        cand = (moniker, ident.group(1), ident.group(2))
        if best is None or _version_tuple(moniker) > _version_tuple(best[0]):
            best = cand
    return best


def pick_download_url(ext_xml: str) -> str:
    urls = [html.unescape(u) for u in re.findall(r"<Url>(http[^<]+)</Url>", ext_xml)]
    for u in urls:
        if "tlu.dl.delivery.mp.microsoft.com" in u:
            return u
    for u in urls:
        if "dl.delivery.mp.microsoft.com" in u:
            return u
    _die("no download URL returned by GetExtendedUpdateInfo2")


def download(url: str, dest: str) -> None:
    tmp = dest + ".part"
    req = urllib.request.Request(url, headers={"User-Agent": DL_UA})
    with urllib.request.urlopen(req, context=_ctx, timeout=120) as r:
        total = int(r.headers.get("Content-Length", "0"))
        got = 0
        first = r.read(4)
        if first[:2] != b"PK":
            _die(f"downloaded data is not an MSIX/zip (magic={first!r})")
        with open(tmp, "wb") as f:
            f.write(first)
            got += len(first)
            while True:
                chunk = r.read(1 << 20)
                if not chunk:
                    break
                f.write(chunk)
                got += len(chunk)
                if total:
                    pct = got * 100 // total
                    sys.stderr.write(
                        f"\r  {got / 1e6:8.1f} MB / {total / 1e6:.1f} MB ({pct}%)")
                    sys.stderr.flush()
    sys.stderr.write("\n")
    os.replace(tmp, dest)


def main() -> None:
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--product-id", default=PRODUCT_ID_DEFAULT,
                    help=f"Microsoft Store product id (default: {PRODUCT_ID_DEFAULT})")
    ap.add_argument("--out-dir", default=here,
                    help="where to save the bundle (default: this folder)")
    ap.add_argument("--print-url", action="store_true",
                    help="only resolve and print the download URL, do not download")
    ap.add_argument("--force", action="store_true",
                    help="re-download even if the target file already exists")
    ap.add_argument("--insecure", action="store_true",
                    help="skip TLS verification (only if your CA store can't verify "
                         "Microsoft's delivery endpoints)")
    args = ap.parse_args()

    if args.insecure:
        global _ctx
        _ctx = ssl._create_unverified_context()
        sys.stderr.write("\033[1;33mwarning:\033[0m TLS verification disabled (--insecure)\n")

    _section("Resolving Latest Bundle")
    sys.stderr.write(f"product id: {args.product_id}\n")
    cat_id, pkg_prefix = get_wu_category_id(args.product_id)
    sys.stderr.write(f"category:   {cat_id}\npackage:    {pkg_prefix}\n")

    cookie = get_cookie()
    sync_xml = sync_updates(cookie, cat_id)
    bundle = pick_bundle(sync_xml, pkg_prefix)
    if not bundle:
        _die("no neutral .msixbundle leaf update found for this product")
    moniker, update_id, revision = bundle
    version = _version_str(moniker)
    filename = f"{pkg_prefix}_{version}.Msixbundle"
    sys.stderr.write(f"version:    {version}\nfilename:   {filename}\n")

    ext_xml = get_ext_info(cookie, update_id, revision)
    url = pick_download_url(ext_xml)

    if args.print_url:
        print(url)
        return

    os.makedirs(args.out_dir, exist_ok=True)
    dest = os.path.join(args.out_dir, filename)
    if os.path.exists(dest) and not args.force:
        _section("Already Present")
        sys.stderr.write(f"file exists, skipping: {dest}\n"
                         "use --force to re-download\n")
        print(dest)
        return

    _section("Downloading")
    download(url, dest)

    _section("Done")
    sys.stderr.write(f"saved: {dest}\n\nnext:\n"
                     f"  ./build-chatgpt-native-deb.sh --exe {dest}\n")
    print(dest)


if __name__ == "__main__":
    try:
        main()
    except urllib.error.URLError as exc:
        _die(f"network/TLS error talking to Microsoft: {exc}\n"
             "       if this is a certificate error, retry with --insecure")
