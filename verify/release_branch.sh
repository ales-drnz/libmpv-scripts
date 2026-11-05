#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# A build stamps LIBMPV_RELEASE of scripts/shared/_versions.sh in the
# version of its binaries ("mpv v0.41.0+rN"), which the kit reads back: on
# any branch it must be of the form rN. A build of a release/rN branch must
# also stamp rN, or the binaries would say another release than the one they
# ship as, and a release branch not named rN fails.
#
# Usage: bash verify/release_branch.sh <branch>    (GITHUB_REF_NAME by default)

set -euo pipefail
branch="${1:-${GITHUB_REF_NAME:-}}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The value the build scripts read, with no LIBMPV_RELEASE from outside.
have="$(env -u LIBMPV_RELEASE bash -c "source '$root/scripts/shared/_versions.sh'; echo \"\$LIBMPV_RELEASE\"")"
if [[ ! "$have" =~ ^r[0-9]+$ ]]; then
  echo "::error title=Release branch::$branch builds LIBMPV_RELEASE \"$have\", not of the form rN: set it in scripts/shared/_versions.sh"
  exit 1
fi
if [[ "$branch" != release/* ]]; then
  echo "release branch: $branch is not one, it builds $have"
  exit 0
fi
want="${branch#release/}"
if [[ ! "$want" =~ ^r[0-9]+$ ]]; then
  echo "::error title=Release branch::$branch is not named release/rN"
  exit 1
fi
if [[ "$have" != "$want" ]]; then
  echo "::error title=Release branch::$branch builds LIBMPV_RELEASE $have: set it to $want in scripts/shared/_versions.sh"
  exit 1
fi
echo "release branch: $branch builds $have"
