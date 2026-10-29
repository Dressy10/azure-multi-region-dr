"""SDK-based writer for the failover drill. Same CSV format as writer.ps1 so the same orchestrator
and analysis work for both clients:
    epoch_ms, seq, http_status, substatus, latency_ms, detail
http_status is 201 for an acknowledged write, the SDK error's status code on failure, or 0 for a
non-HTTP failure. Failed writes are NOT retried by this script (the SDK may retry internally, which
shows up as latency), so acknowledged-but-missing documents would mean real data loss.
"""
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "app", "ledger_dr"))
from azure.cosmos import exceptions  # noqa: E402
from ledger import LedgerStore  # noqa: E402


def main(account: str, run_id: str, out_csv: str, stop_file: str, regions: str) -> None:
    store = LedgerStore(
        endpoint=f"https://{account}.documents.azure.com",
        preferred_regions=[r.strip() for r in regions.split(",")],
    )
    with open(out_csv, "w", encoding="utf-8", buffering=1) as out:
        out.write("epoch_ms,seq,http_status,substatus,latency_ms,detail\n")
        seq = 0
        while not os.path.exists(stop_file):
            seq += 1
            t0 = time.time()
            code, sub, detail = 201, "", ""
            try:
                store.record("drill", f"{run_id}-{seq}", {"runId": run_id, "seq": seq, "ts": int(t0 * 1000)})
            except exceptions.CosmosHttpResponseError as e:
                code, sub = e.status_code or 0, str(getattr(e, "sub_status", "") or "")
                detail = str(e.message or e).replace("\n", " ").replace(",", " ").replace('"', " ")[:110]
            except Exception as e:  # noqa: BLE001 - record anything, the drill must not die mid-run
                code, detail = 0, f"{type(e).__name__}: {e}".replace("\n", " ").replace(",", " ")[:110]
            latency_ms = int((time.time() - t0) * 1000)
            out.write(f"{int(t0 * 1000)},{seq},{code},{sub},{latency_ms},{detail}\n")
            time.sleep(max(0.0, 0.2 - (time.time() - t0)))


if __name__ == "__main__":
    main(*sys.argv[1:6])
