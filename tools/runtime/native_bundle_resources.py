"""Use the production Make resource validator from build and harness tooling."""

from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'telegram-ios/build-system/Make'))
from NativeBundleResources import CONTRACT, source_resources, verify_archive, verify_native_bundle_resources
