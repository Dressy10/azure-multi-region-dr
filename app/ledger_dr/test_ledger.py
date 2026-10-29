"""Unit tests for the idempotency contract. They use a fake container, so they need no Azure access."""
import unittest
from unittest import mock

from azure.cosmos import exceptions

import ledger


def make_store(container):
    store = ledger.LedgerStore.__new__(ledger.LedgerStore)  # bypass __init__: no network, no credentials
    store._container = container
    return store


class RecordTests(unittest.TestCase):
    def test_new_entry_is_stored_and_reports_true(self):
        container = mock.Mock()
        self.assertTrue(make_store(container).record("acct-1", "ref-1", {"amount": 5}))
        container.create_item.assert_called_once_with(body={"amount": 5, "id": "ref-1", "accountId": "acct-1"})

    def test_duplicate_ref_is_success_not_an_error(self):
        container = mock.Mock()
        container.create_item.side_effect = exceptions.CosmosResourceExistsError(status_code=409, message="exists")
        self.assertFalse(make_store(container).record("acct-1", "ref-1"))

    def test_other_errors_propagate(self):
        container = mock.Mock()
        container.create_item.side_effect = exceptions.CosmosHttpResponseError(status_code=500, message="boom")
        with self.assertRaises(exceptions.CosmosHttpResponseError):
            make_store(container).record("acct-1", "ref-1")

    def test_caller_fields_cannot_override_identity(self):
        container = mock.Mock()
        make_store(container).record("acct-1", "ref-1", {"id": "evil", "accountId": "evil"})
        sent = container.create_item.call_args.kwargs["body"]
        self.assertEqual((sent["id"], sent["accountId"]), ("ref-1", "acct-1"))


if __name__ == "__main__":
    unittest.main()
