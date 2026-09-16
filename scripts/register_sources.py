"""Register audited source files and hardware; never solve an optimization model."""
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT))
from go3cpu.contract import load_case, case_manifest
from go3cpu.controller import atomic_json, sha256
from go3cpu.safety import storage_check

PINS = {
    "C3DataUtilities": ("https://github.com/GOCompetition/C3DataUtilities", "bb5df337553b21ab8be89ae5f9106958541730d4"),
    "GO-3-data-model": ("https://github.com/Smart-DS/GO-3-data-model", "5472a2373f456cc7e9923cdd31be1d4345d9830f"),
    "GOC3Benchmark.jl": ("https://github.com/lanl-ansi/GOC3Benchmark.jl", "588f3566ab29df240622a9a98c758af1bfc66bb1"),
}
DOCUMENTS = {
    "formulation_20240122.pdf":"https://data.openei.org/files/5997/Challenge3_Problem_Formulation_20240122.pdf",
    "data_format_20230124.pdf":"https://data.openei.org/files/5997/Challenge3_Data_Format_20230124.pdf",
    "results_20240506.xlsx":"https://data.openei.org/files/5997/E4LB_Master_20240506.xlsx",
}


def git(path,*args):
    return subprocess.check_output(["git","-C",str(path),*args],text=True).strip()


def main():
    config=json.loads((ROOT/"config/pilot.json").read_text())
    case,digest=load_case(ROOT/config["input_path"],config["input_sha256"])
    manifest={"schema_version":1,"network":"C3E4N00617D2","scenario":"002",
        "input_uuid":None,"uuid_note":"No input UUID in raw general fields; published UUIDs identify individual submissions.",
        "selection_rule":"Smallest numeric public 617-bus Final Event Division 2 scenario with matching published records; all 24 published scenario groups have SW=1, so no matched no-switch alternative exists.",
        "archive_url":"https://data.openei.org/files/5997/C3E4N00617_20231002.zip",
        "archive_etag":"\"50df92f-617cc5b71d550\"",
        "archive_entry":"D2/C3E4N00617D2/scenario_002.json",
        "input_sha256":digest,"input_bytes":(ROOT/config["input_path"]).stat().st_size,
        "official_allow_switching":True,"official_division_time_limit_seconds":7200,
        "local_pilot_limit_seconds":config["total_seconds"],
        "unsupported_required_features_present":[],**case_manifest(case)}
    atomic_json(ROOT/"manifests/case.json",manifest)
    sources={"schema_version":1,"upstream":{},"documents":{},
        "historical_evaluator_other_revision":"fabdeb545cd2f471396579e720f355de1e36595f",
        "historical_data_model_revision":"unknown; published cells contain nan",
        "compatibility_document":"docs/FORMULATION_AND_LIMITATIONS.md"}
    for name,(url,expected) in PINS.items():
        directory=ROOT/".cache/upstream"/name
        if git(directory,"rev-parse","HEAD")!=expected or git(directory,"status","--porcelain","--untracked-files=no"):
            raise RuntimeError(f"Upstream pin/cleanliness failure: {name}")
        sources["upstream"][name]={"url":url,"commit":expected,
            "tracked_file_sha256":{f:sha256(directory/f) for f in git(directory,"ls-files").splitlines()}}
    for name,url in DOCUMENTS.items():
        p=ROOT/".cache/sources"/name
        sources["documents"][name]={"url":url,"sha256":sha256(p),"bytes":p.stat().st_size}
    atomic_json(ROOT/"manifests/sources.json",sources)
    print(json.dumps({"case":manifest,"storage":storage_check(ROOT)},indent=2))


if __name__=="__main__":
    main()
