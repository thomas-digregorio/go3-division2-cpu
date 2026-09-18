"""Read source metadata without importing any supplied optimized solution."""

import argparse
import hashlib
import io
import json
from pathlib import Path
import re
import sys
from urllib.request import Request, urlopen
import xml.etree.ElementTree as ET
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from go3cpu.safety import local_path, storage_check

ARCHIVE = "https://data.openei.org/files/5997/C3E4N00617_20231002.zip"
CASE_PATTERN = re.compile(r"D2/C3E4N00617D2/scenario_[0-9]{3}\.json\Z")
NETWORKS = ("C3E4N00617D2", "C3E4N02000D2", "C3E4N04224D2", "C3E4N06049D2",
            "C3E4N06717D2", "C3E4N08316D2", "C3E4N23643D2")
NS = {"s": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}


def archive_source(network):
    if network not in NETWORKS:
        raise ValueError("Network is outside the registered Division 2 scope")
    stem = network if network == "C3E4N08316D2" else network[:-2]
    return (f"https://data.openei.org/files/5997/{stem}_20231002.zip",
            re.compile(r"D2/" + re.escape(network) + r"/scenario_[0-9]{3}\.json\Z"))


class RemoteZip(io.RawIOBase):
    """Bounded HTTP Range reader: never download the whole archive as fallback."""

    def __init__(self, url, max_transfer=16 * 1024 * 1024):
        self.url, self.pos, self.transferred = url, 0, 0
        self.max_transfer = max_transfer
        with urlopen(Request(url, method="HEAD"), timeout=30) as response:
            self.size = int(response.headers["Content-Length"])
            self.etag = response.headers.get("ETag")

    def seekable(self):
        return True

    def tell(self):
        return self.pos

    def seek(self, offset, whence=0):
        self.pos = offset + (0 if whence == 0 else self.pos if whence == 1 else self.size)
        if self.pos < 0:
            raise ValueError("Negative seek")
        return self.pos

    def read(self, size=-1):
        size = min(self.size - self.pos, size if size >= 0 else self.size)
        if size <= 0:
            return b""
        if self.transferred + size > self.max_transfer:
            raise RuntimeError("Refusing an unexpectedly large source transfer")
        headers = {"Range": f"bytes={self.pos}-{self.pos+size-1}"}
        if self.etag:
            headers["If-Match"] = self.etag
        with urlopen(Request(self.url, headers=headers), timeout=30) as response:
            if response.status != 206:
                raise RuntimeError("Server did not honor Range; no full-download fallback")
            expected = f"bytes {self.pos}-{self.pos+size-1}/{self.size}"
            if response.headers.get("Content-Range") != expected:
                raise RuntimeError("Unexpected Content-Range")
            data = response.read(size + 1)
        if len(data) != size:
            raise RuntimeError("Incomplete or oversized source response")
        self.pos += size
        self.transferred += size
        return data


def archive_listing(network="C3E4N00617D2"):
    url, pattern = archive_source(network)
    remote = RemoteZip(url)
    with zipfile.ZipFile(remote) as archive:
        files = [{"path": f.filename, "bytes": f.file_size,
                  "compressed_bytes": f.compress_size, "crc32": f"{f.CRC:08x}"}
                 for f in archive.infolist() if pattern.fullmatch(f.filename)]
    return {"url": url, "etag": remote.etag,
            "archive_bytes": remote.size, "transferred_bytes": remote.transferred,
            "scenario_entries_only": files}


def extract_case(entry, destination, network="C3E4N00617D2"):
    url, pattern = archive_source(network)
    if not pattern.fullmatch(entry):
        raise ValueError("Only an exact registered Division 2 raw scenario entry may be extracted")
    path = local_path(destination)
    if path.exists():
        raise FileExistsError(path)
    storage_check(path, pending_bytes=64 * 1024 * 1024)
    remote = RemoteZip(url)
    with zipfile.ZipFile(remote) as archive:
        info = archive.getinfo(entry)
        if info.file_size > 64 * 1024 * 1024:
            raise RuntimeError("Case exceeds registered download cap")
        data = archive.read(info)  # zipfile verifies CRC
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("xb") as stream:
        stream.write(data)
    return {"entry": entry, "sha256": hashlib.sha256(data).hexdigest(),
            "bytes": len(data), "transferred_bytes": remote.transferred,
            "archive_url": url, "archive_etag": remote.etag}


def workbook_rows(path, sheet_name):
    """Read stored cell values and formulas without recalculation or modification."""
    with zipfile.ZipFile(path) as z:
        strings = []
        if "xl/sharedStrings.xml" in z.namelist():
            root = ET.fromstring(z.read("xl/sharedStrings.xml"))
            strings = ["".join(t.text or "" for t in si.iterfind(".//s:t", NS))
                       for si in root]
        workbook = ET.fromstring(z.read("xl/workbook.xml"))
        rels = {r.attrib["Id"]: r.attrib["Target"] for r in
                ET.fromstring(z.read("xl/_rels/workbook.xml.rels"))}
        sheets = {s.attrib["name"]: rels[s.attrib[
            "{http://schemas.openxmlformats.org/officeDocument/2006/relationships}id"]]
                  for s in workbook.find("s:sheets", NS)}
        if sheet_name not in sheets:
            raise ValueError(f"Available sheets: {list(sheets)}")
        member = sheets[sheet_name]
        member = member.lstrip("/") if member.startswith("/") else "xl/" + member
        with z.open(member) as stream:
            for _, row in ET.iterparse(stream, events=["end"]):
                if row.tag != "{" + NS["s"] + "}row":
                    continue
                cells = {}
                for cell in row:
                    ref = cell.attrib.get("r")
                    val = cell.find("s:v", NS)
                    typ = cell.attrib.get("t")
                    value = None if val is None else val.text
                    if typ == "s" and value is not None:
                        value = strings[int(value)]
                    if typ == "inlineStr":
                        value = "".join(t.text or "" for t in cell.iterfind(".//s:t", NS))
                    formula = cell.find("s:f", NS)
                    if value is not None or formula is not None:
                        cells[ref] = {"value": value, "type": typ,
                                      "formula": None if formula is None else formula.text}
                yield {"row": int(row.attrib["r"]), "cells": cells}
                row.clear()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["archive", "workbook", "extract", "comparison"])
    parser.add_argument("--path")
    parser.add_argument("--sheet", default="617")
    parser.add_argument("--entry")
    parser.add_argument("--limit", type=int, default=12)
    parser.add_argument("--scenario", type=int, default=2)
    parser.add_argument("--network", choices=NETWORKS, default="C3E4N00617D2")
    parser.add_argument("--output")
    args = parser.parse_args()
    if args.command == "archive":
        print(json.dumps(archive_listing(args.network), indent=2))
    elif args.command == "extract":
        print(json.dumps(extract_case(args.entry, args.path, args.network), indent=2))
    elif args.command == "comparison":
        fields = ["team", "model", "scenario", "SW", "objective", "z", "score", "runtime",
                  "timelimit", "feas", "infeas", "uuid", "Div.", "scored", "allow_switching",
                  "evaluation_feas", "evaluation_infeas", "git_info_c3datautilities_commit",
                  "git_info_bid_ds_data_model_commit", "problem_num_buses", "problem_num_intervals",
                  "problem_num_contingencies", "problem_total_duration", "problem_interval_durations",
                  "problem_general_base_norm_mva", "evaluation_pass", "scoring_method", "is_active"]
        headers, selected = {}, []
        for row in workbook_rows(local_path(args.path), "data"):
            cells = {re.sub(r"[0-9]", "", k): v for k, v in row["cells"].items()}
            if row["row"] == 1:
                # Preserve first occurrence of duplicate presentation/raw columns.
                for col, c in cells.items():
                    headers.setdefault(c["value"], col)
                continue
            def value(name):
                return cells.get(headers.get(name), {}).get("value")
            if value("model") != args.network or value("scenario") != str(args.scenario):
                continue
            selected.append({"source_row": row["row"], **{k: value(k) for k in fields}})
        report = {"source_url": "https://data.openei.org/files/5997/E4LB_Master_20240506.xlsx",
                  "sha256": hashlib.sha256(Path(args.path).read_bytes()).hexdigest(),
                  "sheet": "data", "network": args.network, "scenario": args.scenario, "records": selected}
        if args.output:
            path = local_path(args.output)
            path.parent.mkdir(parents=True, exist_ok=True)
            with path.open("x", encoding="utf-8") as stream:
                json.dump(report, stream, indent=2)
        print(json.dumps(report, indent=2))
    else:
        for i, row in enumerate(workbook_rows(local_path(args.path), args.sheet)):
            if i >= args.limit:
                break
            print(json.dumps(row))


if __name__ == "__main__":
    main()
