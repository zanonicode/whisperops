import json
import os
import sys
from pathlib import Path

FIXTURES_DIR = Path(__file__).parent / "fixtures"
VALID_DATASET_IDS = {"california-housing", "online-retail-ii", "spotify-tracks"}
VALID_ARCHETYPES = {"regression", "time-series", "exploratory"}
VALID_MODELS = {"claude-haiku-4-5-20251001", "claude-sonnet-4-5-20251001"}


def validate_fixture(fixture_path: Path) -> list[str]:
    errors: list[str] = []
    with fixture_path.open() as f:
        data = json.load(f)

    required_fields = ["dataset_id", "test_question", "expected_response_shape"]
    for field in required_fields:
        if field not in data:
            errors.append(f"Missing required field: {field}")

    dataset_id = data.get("dataset_id", "")
    if dataset_id not in VALID_DATASET_IDS:
        errors.append(f"Invalid dataset_id '{dataset_id}'; must be one of {VALID_DATASET_IDS}")

    test_question = data.get("test_question", "")
    if not isinstance(test_question, str) or len(test_question) < 5:
        errors.append("test_question must be a non-trivial string")

    expected_shape = data.get("expected_response_shape", {})
    required_shape_keys = ["has_text", "has_chart"]
    for key in required_shape_keys:
        if key not in expected_shape:
            errors.append(f"expected_response_shape missing key: {key}")

    return errors


def validate_manifests() -> bool:
    fixtures = list(FIXTURES_DIR.glob("*.json"))
    if not fixtures:
        print("FAIL  No fixture files found in", FIXTURES_DIR)
        return False

    all_valid = True
    for fixture in sorted(fixtures):
        errors = validate_fixture(fixture)
        if errors:
            print(f"FAIL  {fixture.name}:")
            for err in errors:
                print(f"        - {err}")
            all_valid = False
        else:
            print(f"PASS  {fixture.name}")

    return all_valid


def check_profile_schema_coverage() -> bool:
    profiles_dir = Path(__file__).parent.parent.parent.parent / "src" / "platform-bootstrap" / "profiles"
    if not profiles_dir.exists():
        print("WARN  platform-bootstrap/profiles/ not found; skipping schema coverage check")
        return True

    for dataset_id in VALID_DATASET_IDS:
        profile_file = profiles_dir / f"{dataset_id}.json"
        if not profile_file.exists():
            print(f"FAIL  Missing profile placeholder: {profile_file}")
            return False

        with profile_file.open() as f:
            profile = json.load(f)

        if "dataset_id" not in profile or "csv_filename" not in profile:
            print(f"FAIL  {profile_file.name} missing required keys")
            return False

        print(f"PASS  Profile placeholder: {profile_file.name}")

    return True


def main() -> None:
    print("=== Eval: Fixture Validation ===")
    fixtures_ok = validate_manifests()

    print("")
    print("=== Eval: Profile Schema Coverage ===")
    profiles_ok = check_profile_schema_coverage()

    print("")
    if fixtures_ok and profiles_ok:
        print("=== All evals PASSED ===")
        sys.exit(0)
    else:
        print("=== Some evals FAILED ===")
        sys.exit(1)


if __name__ == "__main__":
    main()
