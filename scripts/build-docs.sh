#!/bin/zsh
# Builds FieldTapeKit's documentation with its Snippets, and fails on any DocC warning
# (docs/DOCUMENTATION_GUIDE.md). It uses only the Xcode toolchain, with no swift-docc-plugin: xcodebuild docbuild
# can't embed Snippets, so this does the plugin's three steps by hand. Run it from the repository root.
#
# The archive is written to .build/docs/FieldTapeKit.doccarchive.
set -euo pipefail

export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode-27.2.0.app/Contents/Developer}
root=${0:A:h:h}
work=$root/.build/docs
rm -rf $work
mkdir -p $work/graphs

cd $root
# 1. FieldTapeKit's public symbols, from SwiftPM. This builds the package, and so compiles every snippet too.
xcrun swift package dump-symbol-graph --skip-synthesized-members --emit-extension-block-symbols >/dev/null
cp .build/*/symbolgraph/FieldTapeKit*.symbols.json $work/graphs/

# 2. The snippets, as SwiftPM's docc plugin would extract them.
xcrun snippet-extract --output $work/graphs/FieldTapeKit-snippets.symbols.json --module-name FieldTapeKit \
    $root/Snippets/**/*.swift

# 3. The catalog, with both, treating every warning as an error.
xcrun docc convert Sources/FieldTapeKit/FieldTapeKit.docc \
    --additional-symbol-graph-dir $work/graphs \
    --fallback-display-name FieldTapeKit --fallback-bundle-identifier com.jnjosh.FieldTapeKit \
    --output-dir $work/FieldTapeKit.doccarchive \
    --warnings-as-errors

echo "Built $work/FieldTapeKit.doccarchive"
