.PHONY: foxtrot.h
foxtrot.h:
	cbindgen ffi -o QuickLookStep/foxtrot.h -l c

# Apple Silicon only (the Xcode project sets ARCHS = arm64). The file keeps its
# historical "universal" name so the Xcode project's file reference is unchanged.
.PHONY: libfoxtrot_universal.a
libfoxtrot_universal.a:
	cargo build --release --target aarch64-apple-darwin -p foxtrot_ffi
	cp target/aarch64-apple-darwin/release/libfoxtrot_ffi.a QuickLookStep/libfoxtrot_universal.a

.PHONY: test-foxtrot
test-foxtrot:
	cd foxtrot && cargo run --release -- examples/cube_hole.step

.PHONY: xcodebuild
xcodebuild:
	xcodebuild \
	  -project QuickLookStep/QuickLookStep.xcodeproj \
	  -scheme QuickLookStep \
	  -configuration Release \
	  -destination 'generic/platform=macOS' \
	  -derivedDataPath build \
	  build
