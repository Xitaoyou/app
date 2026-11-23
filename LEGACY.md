# NeoFreeBird for X 10.79.2

This branch builds NeoFreeBird 7.3.1 against X 10.79.2 for initial device testing.
Run the branch's **Build NeoFreeBird Legacy 10.79.2** workflow to create the private draft.
The base IPA is supplied by the repository secret `NFB_DECRYPTED_IPA_URL_10_79_2`.
The 12.42.1 branch and SideStore feed are separate.

The build uses the app's native Media tab. The regular FreeBird settings entry,
post video and GIF download menu, ad filtering, and timeline filters use interfaces
present in 10.79.2. The update path uses the legacy sections selector.

The first build omits Drive archiving, the new profile copy menu, the iPad
split column, the modern collapsing tab bar, Liquid Glass controls, the blue
launch screen, the Grok UI controls, newer chat privacy controls, and the
new immersive double-tap option. New X Chat attachment hooks have no target in
this version. Other private hooks can also be inert when the old class is absent.

The workflow checks ZIP integrity, version, bundle ID, deployment target, and
injection contents before upload. On device, check launch, sign-in, the settings
entry, feed filtering, video and GIF download, and native Media scrolling and playback.
Both builds use the same original bundle ID.
