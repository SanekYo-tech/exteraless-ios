"""Domain evidence contracts. These inspect real app reports, never render a UI."""

import hashlib
import json
import re

from client_ui_harness_visuals import VISUAL_SCENARIOS, check_visual_sources

DOMAIN_SCENARIOS = ("feed-render", "player-render", "pill-render")
PROBES = {
    "feed-render": ["home", "feed-initial", "feed-albums", "feed-edited", "feed-dark", "feed-bottom-player", "feed-top-player", "feed-cleanup"],
    "player-render": ["home", "player-plain-light", "player-plain-dark", "player-karaoke-light", "player-paused-scrolled", "player-paused-dark", "player-mini-64", "player-mini-52-top", "player-cleanup"],
    "pill-render": ["home", "pill-cache-initial", "pill-last-hidden", "pill-independent-settings", "pill-cache-enabled",
                    "pill-dark-header", "pill-provider-loading", "pill-provider-ready", "pill-cancel-pending", "pill-reloaded", "pill-cleanup"],
}
MANIFEST_RESOURCE = "client-ui-domain-sources.json"
REQUIRED_SOURCE_SUFFIXES = (
    "/Account/Account.swift", "/ExteralessClientAPIEnvironment.swift", "/RetentionProcessScope.swift",
    "/ExteralessFeedSmoke.swift", "/ExteralessFeedMessageProjection.swift", "/ExteralessFeedMessageCell.swift",
    "/ExteralessPlayerSurface.swift", "/ExteralessPlayerLyricsView.swift", "/ExteralessPlayerOcclusionPublisher.swift",
    "/ExteralessPlayerVisualSurface.swift",
    "/ExteralessPillIntegration.swift", "/ExteralessPillStack.swift", "/PillPluginRegistry.swift",
    "/ClientHarnessBootstrap.swift",
)


def selected_scenarios(requested, baseline):
    selected = tuple(requested) if requested else tuple(baseline)
    if len(selected) > 3 or len(set(selected)) != len(selected):
        raise ValueError("A batch contains at most three distinct scenarios")
    if any(name not in tuple(baseline) + DOMAIN_SCENARIOS + VISUAL_SCENARIOS for name in selected):
        raise ValueError("Unknown UI scenario")
    if sum(bool(set(selected) & set(group)) for group in (baseline, DOMAIN_SCENARIOS, VISUAL_SCENARIOS)) != 1:
        raise ValueError("Select one explicit batch: baseline (3), domains (3), or final visuals (2)")
    return selected


def batch_name(selected, baseline):
    for name, group in (("baseline-3", baseline), ("domains-3", DOMAIN_SCENARIOS), ("final-visuals-2", VISUAL_SCENARIOS)):
        if set(selected) <= set(group):
            return name
    raise ValueError("Unrecognized scenario batch")


def complete_batch(selected, scenarios, recordings):
    return (0 < len(selected) <= 3
            and [item.get("scenario") for item in scenarios] == list(selected)
            and all(item.get("semanticPassed") is True for item in scenarios)
            and [item.get("scenario") for item in recordings] == list(selected))


def check_manifest(value):
    if value.get("format") != "exteraless-ui-domain-sources/1" or not isinstance(value.get("files"), dict):
        raise ValueError("Missing build-time domain source manifest")
    files = value["files"]
    for key, sha in files.items():
        if (not isinstance(key, str) or not key.startswith(("telegram-ios/", "swift/ExteralessCore/"))
                or ".." in key.split("/") or "\\" in key or not isinstance(sha, str) or not re.fullmatch(r"[0-9a-f]{64}", sha)):
            raise ValueError("Invalid domain source fingerprint entry")
    if any(not any(key.endswith(suffix) for key in files) for suffix in REQUIRED_SOURCE_SUFFIXES):
        raise ValueError("Incomplete native/bootstrap/renderer source fingerprint graph")
    canonical = "".join(sha + "  " + key + "\n" for key, sha in sorted(files.items()))
    if hashlib.sha256(canonical.encode("utf-8")).hexdigest() != value.get("sha256"):
        raise ValueError("Domain source manifest digest mismatch")
    return value


def manifest_from_ipa(archive, app_root, scenarios=()):
    value = check_manifest(json.loads(archive.read(app_root + "/" + MANIFEST_RESOURCE)))
    check_visual_sources(value, scenarios)
    return value


def validate_domain(state, scenario):
    if [probe.get("name") for probe in state.get("probes", [])] != PROBES[scenario]:
        raise ValueError("Missing/reordered domain UIKit probes")
    facts = state.get("facts", {})
    if state.get("pythonRequested") is not False:
        raise ValueError("Native domain scenarios must not start the SDK plugin runtime")
    check_manifest(facts.get("domainSources", {}))
    bootstrap = facts.get("bootstrap", {})
    if (bootstrap.get("apiIdentity") != "synthetic-private-fixture-store" or bootstrap.get("systemKeychain") is not False
            or bootstrap.get("retention") != "registered-main-application-snapshot-before-writer"):
        raise ValueError("Account/bootstrap boundary was not established")
    domain = facts.get("domain", {})
    if domain.get("name") != scenario or domain.get("realNativeRenderer") is not True or domain.get("cleanup") is not True:
        raise ValueError("Domain renderer did not finish and release its owned UI")
    if scenario == "feed-render":
        ids = domain.get("messageIds", [])
        if len(ids) != 6 or len(set(ids)) != 6 or domain.get("postCount") != 4:
            raise ValueError("Feed composite message/album identities were lost")
        if domain.get("projectionVerified") is not True or domain.get("namespaceIsolation") is not True:
            raise ValueError("Feed native projection/namespace checks did not execute")
    elif scenario == "player-render":
        if domain.get("seekCount") != 0 or domain.get("pausedPosition") != domain.get("finalPosition"):
            raise ValueError("Paused player styling/scrolling caused playback effects")
        if domain.get("samePositionTickPreservedOffset") is not True or domain.get("surfacesStopped") is not True:
            raise ValueError("Actual Player surface following/cleanup failed")
    else:
        final = domain.get("final", {})
        owners = final.get("owners", [])
        providers = final.get("providers", [])
        if len(owners) != 3 or len(set(owners)) != 3 or len(providers) != 3:
            raise ValueError("Pill pending-cancel/replacement generations were not exercised")
        if any(item.get("starts") != 1 or item.get("cancellations") != 1 for item in providers):
            raise ValueError("Pill native subscriptions leaked or started more than once")
