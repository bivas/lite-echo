import pytest


def pytest_collection_modifyitems(config, items):
    """Deselect integration tests unless `-m` is given explicitly."""
    if config.getoption("-m"):
        return
    skip = pytest.mark.skip(reason="integration test: run with `pytest -m integration`")
    for item in items:
        if "integration" in item.keywords:
            item.add_marker(skip)
