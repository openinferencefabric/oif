# Brand

The Open Inference Fabric mark, "weave to tokens": two GPU vendors' threads (teal and saffron) woven together by the
scheduler's thread (ink), which leaves the cloth as a stream of tokens. Bare metal to tokens.

| File | Use |
| --- | --- |
| `oif-logo-light-1200x400.png`, `oif-logo-dark-1200x400.png` | Logo with the name, for READMEs, slides and web pages |
| `oif-mark-light.svg`, `oif-mark-dark.svg` | The mark alone, as vector |
| `oif-avatar-light-512.png`, `oif-avatar-dark-512.png` | Square avatar: GitHub, Slack, social profiles |
| `oif-social-light-1280x640.png`, `oif-social-dark-1280x640.png` | Repository social preview, link cards |
| `oif-icon-light-32.png`, `oif-icon-light-180.png` | Favicon and touch icon |

`-light` files are for light backgrounds, `-dark` files for dark ones. The gaps in the weave are drawn in the
background colour, so use each file on its own background.

| Colour | Light | Dark |
| --- | --- | --- |
| Fabric teal | `#0E7C86` | `#2BA7B1` |
| Saffron | `#E39A2D` | `#F0AE48` |
| Ink | `#16202A` | `#E6EBEE` |

The name is set in Bricolage Grotesque Bold, lowercase, with "fabric" in teal; text in IBM Plex Sans. Both fonts are
free under the SIL Open Font License.

The mark is vendor-neutral on purpose: no NVIDIA green or AMD red. Use NVIDIA and AMD logos only in factual lists of
supported hardware, following each company's trademark guidelines.

The logo is licensed with the rest of the repository (Apache-2.0). Use it to refer to the project; do not use it in a way
that suggests the project endorses a product or service.

## Team

Email signatures and profile photos for the people who represent OIF, in the brand's colours and type, all generated
by `team/make_signature.py` from a square portrait on white (its docstring has the one-line Docker command):

| File | Use |
| --- | --- |
| `team/oif-signature-<name>-1200x360.png` | Email signature banner: insert it at 600 px wide below a text signature (many mail clients block images, and text keeps the details readable) |
| `team/oif-signature-<name>-600x180.png` | The same at 1x, for clients that do not scale images |
| `team/oif-profile-<name>-512.png` | Round portrait with the OIF mark as a badge: mail account, GitHub, Slack, LinkedIn |
| `team/<name>-portrait-512.png` | The source portrait |

Current: Manmohan Brahma, Project Lead (`manmohan@openinferencefabric.us.ci`). Rerun the script when a role or address
changes rather than editing the images. Portraits are personal: a person's photo is used only for that person, with
their consent, and the Apache-2.0 licence of the repository does not grant rights to use anyone's likeness.
