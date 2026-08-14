.PHONY: version validate release-check prepare-release

version:
	@cat VERSION

validate:
	@python3 -m json.tool appsmith/MushroomProcess.json >/dev/null
	@python3 -m py_compile scripts/*.py
	@node scripts/sync_navigation.js --check
	@python3 scripts/reporting_appsmith_check.py

release-check: validate
	@python3 scripts/prepare_release.py --check

prepare-release:
	@if [ -z "$(VERSION)" ]; then echo "Usage: make prepare-release VERSION=x.y.z [RELEASE_DATE=YYYY-MM-DD]"; exit 1; fi
	@python3 scripts/prepare_release.py --version "$(VERSION)" $(if $(RELEASE_DATE),--release-date "$(RELEASE_DATE)",)
