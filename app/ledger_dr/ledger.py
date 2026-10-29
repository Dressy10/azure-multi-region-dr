"""DR-aware ledger store on Cosmos DB.

Design points, each one driven by the failover drills in docs/drills/:
  * Entra ID auth only (the account has local/key auth disabled). No secrets in code or config.
  * `preferred_locations` lists the regions in order, and the SDK's endpoint discovery follows a
    write-region change by itself. A bare REST client does not: in the drill it kept hitting the old
    write region and got HTTP 403 sub-status 3 for roughly 77 to 82 seconds.
  * Writes are idempotent by `ref` (the document id). A retry after a timeout or an unknown outcome
    can never create a duplicate: a 409 means "already stored", which is success.
"""
from __future__ import annotations

from typing import Any, Iterable, Optional

from azure.cosmos import CosmosClient, exceptions
from azure.identity import DefaultAzureCredential


class LedgerStore:
    def __init__(
        self,
        endpoint: str,
        preferred_regions: Iterable[str],
        credential: Optional[Any] = None,
        database: str = "drdb",
        container: str = "ledger",
    ) -> None:
        cred = credential or DefaultAzureCredential()
        self._client = CosmosClient(
            endpoint,
            credential=cred,
            preferred_locations=list(preferred_regions),
        )
        self._container = self._client.get_database_client(database).get_container_client(container)

    def record(self, account_id: str, ref: str, fields: Optional[dict] = None) -> bool:
        """Store one ledger entry. Returns True if newly stored, False if `ref` already existed.

        Safe to call again with the same `ref` after any failure: the outcome is the same.
        """
        body = dict(fields or {})
        body.update({"id": ref, "accountId": account_id})
        try:
            self._container.create_item(body=body)
            return True
        except exceptions.CosmosResourceExistsError:
            return False
