#!/bin/sh
# Prints the version a release cut from this tree would carry: the minor after
# the newest v-tag, or 1.0.0 when there are none.
#
# The release workflow uses it to decide what to publish, and `make install`
# uses it to stamp local builds. That shared answer is the point: a locally
# installed build claims the version it would be published as, so it is never
# behind the release the updater is watching for and never replaces itself with
# the work it was built from.
#
# Only the minor moves. A major bump is a deliberate act — run the Release
# workflow by hand with an explicit version — and the patch stays 0 so the
# sequence reads v1.1.0, v1.2.0, v1.3.0.
set -eu

latest=$(git tag -l 'v[0-9]*' --sort=-v:refname | head -1)

if [ -z "$latest" ]; then
    echo "1.0.0"
    exit 0
fi

base=${latest#v}
major=${base%%.*}
rest=${base#*.}
minor=${rest%%.*}

case "$major" in ''|*[!0-9]*) echo "cannot read a major version from tag $latest" >&2; exit 1 ;; esac
case "$minor" in ''|*[!0-9]*) echo "cannot read a minor version from tag $latest" >&2; exit 1 ;; esac

echo "$major.$((minor + 1)).0"
