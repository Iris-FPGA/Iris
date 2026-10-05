#!/usr/bin/env python3
"""Headless SapphireSoc (efx_soc) IP generation for the Iris project.

Mirrors the Efinity IP Manager "import settings.json -> generate" flow without
starting the Qt GUI. Requires a sourced Efinity environment (EFINITY_HOME).

Usage (normally via .script/gen-sapphire-soc):
    python3 gen-sapphire-soc.py --project-dir <dir> [--name SapphireSoc]
"""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

def _bootstrap_efinity() -> None:
    ef = os.environ.get("EFINITY_HOME")
    if not ef:
        sys.exit("EFINITY_HOME is not set; source <efinity>/bin/setup.sh first")
    sys.path.insert(0, str(Path(ef) / "ipm" / "bin"))
    from common.util import set_efinity_user_dir_env  # pylint: disable=import-error
    set_efinity_user_dir_env()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--project-dir", required=True, help="Efinity project directory")
    ap.add_argument("--name", default="SapphireSoc", help="IP instance/module name")
    ap.add_argument("--device", default="Ti60F225")
    ap.add_argument("--family", default="Titanium")
    args = ap.parse_args()

    _bootstrap_efinity()

    import gui.api_wrapper as wrapper  # pylint: disable=import-error
    from common.logger import Logger  # pylint: disable=import-error
    from common.util import get_default_log_path  # pylint: disable=import-error
    from efx_ipmgr.production_api.type_class.to_object import (  # pylint: disable=import-error
        toObject,
    )
    from efx_ipmgr.production_api.utility.utility import (  # pylint: disable=import-error
        create_new_parameter_template_by_value,
    )

    # Route Efinix IPM messages into a file so swallowed exceptions are visible.
    log_path = get_default_log_path("")
    Logger.setup_logger(log_path, None, "efxIP.log")
    log_file = Path(log_path) / "efxIP.log"
    print(f"[gen] ipm log: {log_file}")

    project = Path(args.project_dir).resolve()
    settings_path = project / "ip" / args.name / "settings.json"
    if not settings_path.is_file():
        sys.exit(f"missing settings.json: {settings_path}")

    setting = wrapper.get_parsed_settings_json(
        settings_path=str(settings_path), should_log=False
    )
    if setting is None:
        sys.exit(f"failed to parse {settings_path}")
    if setting.gen_name != args.name:
        sys.exit(f"settings gen_name={setting.gen_name} != --name {args.name}")

    vlnv = setting.vlnv

    # The checked-in settings.json may reference an older efx_soc version than
    # the installed IP catalog. Rebind to the installed version of the same
    # vendor/library/name (migration is only a version bump; parameter
    # compatibility is re-checked by validate_params below).
    installed = [
        v for v in wrapper.get_list_of_ips(
            vlnv.vendor, vlnv.library, device_name=args.device,
            family_name=args.family, should_log=False,
        )[0]
        if v.name == vlnv.name
    ]
    if not installed:
        sys.exit(f"IP {vlnv} not found in the installed catalog")
    target = sorted(installed, key=lambda v: v.version)[-1]
    if target.version != vlnv.version:
        print(f"[gen] efx_soc {vlnv.version} -> installed {target.version}")
        vlnv = target
        setting.vlnv = target
        # Keep settings.json in sync: the generator re-loads the file and must
        # not race against the stale version recorded inside it.
        import json
        raw = json.loads(settings_path.read_text())
        for entry in raw.get("args", []):
            if isinstance(entry, dict) and entry.get("name") == target.name:
                entry["version"] = target.version
        settings_path.write_text(json.dumps(raw, indent=4) + "\n")

    # Ensure the IP backend can locate the catalog (loads ip_component.xml /
    # component pickles for this VLNV).
    wrapper.refresh_ip_sources(
        opt=None, vlnv=vlnv, project_ipm_path="",
        device=args.device, family=args.family,
    )

    templates = wrapper.get_ip_params(
        vlnv=vlnv, device_name=args.device, family_name=args.family,
        should_log=False,
    )
    by_name = {t.name: t for t in templates}
    missing = [k for k in setting.params if k not in by_name]
    if missing:
        # Older/newer settings carry parameters the installed IP no longer
        # knows; drop them like the GUI migration does, but loudly.
        print(f"[gen] dropping unknown params: {', '.join(sorted(missing))}")
    user_params = [
        create_new_parameter_template_by_value(by_name[k], v)
        for k, v in setting.params.items()
        if k in by_name
    ]

    validated, param_list, component, graph = wrapper.validate_params(
        vlnv=vlnv, params_to_chk=user_params, device_name=args.device,
        family_name=args.family, should_log=False,
    )
    if not validated.result:
        exc, err, warn = validated.error_tuple_msg
        for name, msgs in list(exc.items()) + list(err.items()) + list(warn.items()):
            print(f"[gen] param {name}: {msgs}", file=sys.stderr)
        sys.exit("parameter validation failed")
    wrapper.update_model(vlnv=vlnv, comp=component, graph=graph)

    deliverables = wrapper.get_ip_filesets(
        vlnv=vlnv, should_log=False, temp_component_template=toObject(component)
    )
    wanted = set(setting.output_filesets)
    filesets = [
        d.fileset_template for d in deliverables
        if (not d.is_optional) or (d.fileset_template.get_ip_fileset_name() in wanted)
    ]

    print(f"[gen] generating {args.name} ({vlnv.name} {vlnv.version}) "
          f"into {project / 'ip' / args.name}")
    result = wrapper.generate_ip(
        vlnv=vlnv,
        params=param_list,
        filesets=filesets,
        out_path=str(project),
        user_ip_path=str(project),
        external_file_path_option=2,  # RELATIVE_PATH
        gen_name=args.name,
        device_name=args.device,
        family_name=args.family,
        setting_path=str(settings_path),
        is_del_settings_json=False,
        skip_put_params=True,
        project_name=project.stem,
        peri_xml_file_path=str(project / f"{project.stem}.peri.xml"),
        project_xml_path=str(project / f"{project.stem}.xml"),
        postmap_module_enable="false",
    )
    print(f"[gen] result: {result}")
    gen_dir = project / "ip" / args.name
    produced = sorted(p.name for p in gen_dir.iterdir()) if gen_dir.is_dir() else []
    print(f"[gen] ip/{args.name}: {', '.join(produced) or '(empty)'}")
    if str(result).endswith("GENERIC_ERROR") and log_file.is_file():
        lines = log_file.read_text(errors="replace").splitlines()
        print("----- ipm log tail -----", file=sys.stderr)
        print("\n".join(lines[-60:]), file=sys.stderr)
    return 0 if str(result).endswith("SUCCESS") else 1


if __name__ == "__main__":
    sys.exit(main())
