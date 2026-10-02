# PowerPlay Release Checklist

Use this checklist before creating a tagged release or publishing a more complete receiver build.

## Core project health

- [ ] Confirm the repository is clean and the current branch is ready for release.
- [ ] Review the current README and project overview for the latest PowerPlay branding.
- [ ] Confirm the project builds with the expected legacy syntax-check or Xcode workflow.
- [ ] Verify all project files are organized under the intended Tiger-era layout.

## App functionality

- [ ] Confirm the app launches without runtime crashes in the expected target environment.
- [ ] Verify Bonjour discovery logic is still in place and usable for AirPlay sources.
- [ ] Verify RTSP negotiation and session setup remain coherent.
- [ ] Verify RTP packet handling and ALAC decode boundaries are still aligned with the sender model.
- [ ] Verify CoreAudio playback still receives PCM output in a stable path.
- [ ] Verify cover-art and metadata parsing are still extracted correctly from packets.
- [ ] Verify the Growl notifier shows track metadata and cover art when available.

## Legacy compatibility

- [ ] Confirm target OS compatibility matches the intended Tiger-era constraints.
- [ ] Confirm Objective-C code remains compatible with the selected toolchain.
- [ ] Check for deprecated APIs or build warnings that block compatibility.
- [ ] Confirm non-ARC usage remains consistent with the legacy target if required.

## Packaging

- [ ] Confirm the app name is PowerPlay across the main window, plist metadata, and docs.
- [ ] Verify the final bundle metadata and nib files are present.
- [ ] Confirm any generated or local artifacts are excluded from the release bundle if appropriate.
- [ ] Add or update any relevant release notes for the current milestone.

## Final release steps

- [ ] Run the final validation command(s).
- [ ] Review the git diff before tagging.
- [ ] Create the release tag.
- [ ] Push the code, tag, and release notes to GitHub.
- [ ] Archive screenshots or short demo notes if needed for visibility.

## Suggested next release criteria

A release is ready when all high-risk items above are green and the app can complete at least one realistic sender handshake with no protocol regressions.
