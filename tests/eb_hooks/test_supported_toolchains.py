# Unit tests for the supported top-level toolchains (eessi_supported_toolchains.json)
# and the function in eb_hooks.py that loads them.
# Requires EasyBuild to be importable, e.g.: pip install easybuild pytest
import json
import os
import sys

import pytest

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
sys.path.insert(0, REPO_ROOT)

import eb_hooks  # noqa: E402
from easybuild.tools.build_log import EasyBuildError  # noqa: E402

TOOLCHAINS_FILE = os.path.join(REPO_ROOT, 'eessi_supported_toolchains.json')
ENVVAR = 'EESSI_SUPPORTED_TOOLCHAINS_FILE'


@pytest.fixture(autouse=True)
def clean_env(monkeypatch):
    monkeypatch.delenv(ENVVAR, raising=False)


def write_json(path, content):
    path.write_text(content if isinstance(content, str) else json.dumps(content))
    return str(path)


def test_json_format():
    """Check that the shipped JSON file has the expected structure."""
    with open(TOOLCHAINS_FILE) as fh:
        data = json.load(fh)

    assert isinstance(data, dict) and data
    for eessi_version, toolchains in data.items():
        assert isinstance(eessi_version, str)
        assert isinstance(toolchains, list) and toolchains, f"No toolchains for {eessi_version}"
        for tc in toolchains:
            assert set(tc) <= {'name', 'version', 'min_easybuild_version'}, tc
            assert isinstance(tc.get('name'), str) and tc['name'], tc
            assert isinstance(tc.get('version'), str) and tc['version'], tc
            if 'min_easybuild_version' in tc:
                assert isinstance(tc['min_easybuild_version'], str), tc
        # no duplicates
        pairs = [(tc['name'], tc['version']) for tc in toolchains]
        assert len(pairs) == len(set(pairs)), f"Duplicate toolchains for {eessi_version}"


def test_load_default_location():
    """Without the environment variable, the file next to eb_hooks.py is used."""
    result = eb_hooks.load_supported_top_level_toolchains()
    assert set(result) == set(json.load(open(TOOLCHAINS_FILE)))
    for tcs in result.values():
        for tc in tcs:
            assert set(tc) == {'name', 'version'}


@pytest.mark.parametrize('eb_version, lfoss_present, rompi_present', [
    ('5.1.0', False, False),
    ('5.2.0', True, False),
    ('5.3.0', True, False),
    ('5.3.1', True, True),
    ('5.4.0', True, True),
])
def test_min_easybuild_version(monkeypatch, eb_version, lfoss_present, rompi_present):
    monkeypatch.setattr(eb_hooks, 'EASYBUILD_VERSION', eb_version)
    tcs = eb_hooks.load_supported_top_level_toolchains()['2025.06']
    assert ({'name': 'lfoss', 'version': '2025b'} in tcs) == lfoss_present
    assert ({'name': 'rompi', 'version': '2025a'} in tcs) == rompi_present
    # toolchains without a minimum EasyBuild version are always there
    assert {'name': 'foss', 'version': '2025b'} in tcs


def test_envvar_overrides_location(monkeypatch, tmp_path):
    custom = write_json(tmp_path / 'custom.json', {'2099.01': [{'name': 'foo', 'version': '1'}]})
    monkeypatch.setenv(ENVVAR, custom)
    assert eb_hooks.load_supported_top_level_toolchains() == {'2099.01': [{'name': 'foo', 'version': '1'}]}


def test_envvar_missing_file(monkeypatch, tmp_path):
    missing = str(tmp_path / 'does_not_exist.json')
    monkeypatch.setenv(ENVVAR, missing)
    with pytest.raises(EasyBuildError) as excinfo:
        eb_hooks.load_supported_top_level_toolchains()
    msg = str(excinfo.value)
    assert missing in msg
    assert ENVVAR in msg
    # the file in the default location exists, so the user should be pointed to it and told how to use it
    assert TOOLCHAINS_FILE in msg
    assert f"unset {ENVVAR}" in msg


def test_missing_default_file(monkeypatch, tmp_path):
    monkeypatch.setattr(eb_hooks, '__file__', str(tmp_path / 'eb_hooks.py'))
    with pytest.raises(EasyBuildError) as excinfo:
        eb_hooks.load_supported_top_level_toolchains()
    msg = str(excinfo.value)
    assert str(tmp_path / 'eessi_supported_toolchains.json') in msg
    assert ENVVAR in msg  # mentions how to configure the location
    assert 'unset' not in msg


@pytest.mark.parametrize('use_envvar', [False, True])
def test_invalid_json(monkeypatch, tmp_path, use_envvar):
    bad = write_json(tmp_path / 'bad.json', '{"2025.06": [')
    if use_envvar:
        monkeypatch.setenv(ENVVAR, bad)
    else:
        monkeypatch.setattr(eb_hooks, '__file__', str(tmp_path / 'eb_hooks.py'))
        os.rename(bad, tmp_path / 'eessi_supported_toolchains.json')
    with pytest.raises(EasyBuildError, match='does not contain valid JSON'):
        eb_hooks.load_supported_top_level_toolchains()
