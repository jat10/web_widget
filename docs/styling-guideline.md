# Widget styling guideline

Customize the widget through the CSS custom properties listed below. Define them
in a CSS file and supply its URL using the embed script's optional `stylesheet-url`
attribute. You only need to override the properties you want to change.

## Load your stylesheet

```html
<script
  src="http://localhost:4000/web_widget/assets/embed.js"
  data-widget-id="13"
  data-token-url="/api/widget-token"
  stylesheet-url="/widget-brand.css"
  defer>
</script>
```

The stylesheet loads **inside the iframe**. Adding it only to the parent page does
not style the widget, because CSS does not cross the iframe boundary.
Authenticated installations fetch the initial identity token from the parent
page's same-origin `data-token-url`; the stylesheet is delivered during iframe
bootstrap before public `zaq:ready`. Neither URL contains the connector key.

- `/widget-brand.css` resolves against the parent page's origin.
- `./styles/widget.css` resolves against the parent document's base URL, including
  any HTML `<base>` element.
- An absolute URL such as `https://your-app.example/styles/widget.css` also works.
- The resolved URL must use HTTP or HTTPS, without embedded username/password
  credentials. Empty values, whitespace and backslashes are rejected.
- Serve the file as CSS without a login redirect. Use HTTPS when the iframe uses
  HTTPS; the iframe's content security policy must permit the stylesheet host.
- Omit the attribute to use the bundled styles. If the CSS cannot load, the
  bundled styles remain available. Runtime config `stylesheet_url` is no longer
  used to load custom CSS.

For example, on `http://localhost:4010`, `/widget-brand.css` loads
`http://localhost:4010/widget-brand.css`, even if the widget runs on port 4000.
URLs referenced **within that CSS file**, such as font or image URLs, resolve
relative to the stylesheet URL.

## Supported color properties

All properties in this table accept CSS color values, for example `#7c3aed`,
`rgb(124, 58, 237)`, or `light-dark(#7c3aed, #a78bfa)`.

| Property | What it changes | Light default | Dark default |
| --- | --- | --- | --- |
| `--zaq-widget-primary` | Send button, links, activity icons, focus accents and selected conversation text | `#027589` | `#0aadca` |
| `--zaq-widget-on-primary` | Text/icons on primary-colored surfaces, including the send button | `#ffffff` | `#040b12` |
| `--zaq-widget-background` | Open conversation background and reopen button background | `#fafafa` | `#040b12` |
| `--zaq-widget-text` | Main text and close icon | `#0c1324` | `#f3f5f7` |
| `--zaq-widget-muted` | Placeholder, timestamps, secondary labels and footer text | `#43536d` | `#a0b2c8` |
| `--zaq-widget-composer-background` | Message composer, activity-step surfaces and conversation sidebar | `#ffffff` | `#0d141c` |
| `--zaq-widget-elevated` | User message bubbles, Markdown code backgrounds and table headings | `#e2e8f0` | `#1f2b35` |
| `--zaq-widget-accent-background` | Selected conversation background when the conversation list is enabled | `#e6f8fb` | `#031d2a` |
| `--zaq-widget-border` | Composer, close button, dividers, activity-step and Markdown borders | `#e2e8f0` | `#1f2b35` |
| `--zaq-widget-shadow` | Composer shadow color; the shadow's offset and blur remain fixed | `#0000000c` | `#00000040` |
| `--zaq-widget-error-border` | Failed activity, failed step and response-error borders | `#ea003e` | `#7f1d2f` |
| `--zaq-widget-error-background` | Failed activity and response-error backgrounds | `#fffafa` | `#200d12` |
| `--zaq-widget-error-text` | Error text, failed-step icons and failed status text | `#b70030` | `#ff6b82` |
| `--zaq-widget-error-badge` | Failed-step status badge background | `#fffafa` | `#200d12` |

Several hover states and subtle backgrounds are derived from these colors using
`color-mix()`. They do not have separate custom properties.

## Supported typography and layout properties

| Property | Value type | Default | What it changes |
| --- | --- | --- | --- |
| `--zaq-widget-font-family` | CSS font-family list | `system-ui, sans-serif` | Main widget font; Markdown code retains its monospace font |
| `--zaq-widget-radius` | CSS length, such as `18px` | `18px` | Composer and user message corner radius; send button uses this minus `7px` |
| `--zaq-widget-max-width` | CSS length, such as `760px` | `760px` | Launcher and conversation content width limit; does not size the outer iframe |
| `--zaq-widget-edge` | CSS length, such as `16px` | `16px` | Launcher edge spacing and conversation content/footer padding |

Use nonnegative spacing values and a radius of at least `7px` so the derived send
button radius stays valid. A custom font must also be available inside the iframe;
use `@font-face` in your stylesheet if needed, with appropriate font-host CORS.

## Example: custom brand colors

Save this as `widget-brand.css` on your parent application's web server:

```css
:root {
  --zaq-widget-primary: #7c3aed;
  --zaq-widget-on-primary: #ffffff;
  --zaq-widget-background: #faf8ff;
  --zaq-widget-text: #221538;
  --zaq-widget-muted: #756587;
  --zaq-widget-composer-background: #ffffff;
  --zaq-widget-elevated: #ede9fe;
  --zaq-widget-accent-background: #ede9fe;
  --zaq-widget-border: #ddd6fe;
  --zaq-widget-shadow: rgb(76 29 149 / 12%);

  --zaq-widget-font-family: system-ui, sans-serif;
  --zaq-widget-radius: 18px;
  --zaq-widget-max-width: 760px;
  --zaq-widget-edge: 16px;
}
```

Put these declarations outside a CSS `@layer`; the bundled defaults use a low
priority theme layer, so ordinary custom declarations override them without
`!important`. Unknown custom property names have no effect unless your own CSS
uses them.

## Light and dark themes

Fixed colors apply in both themes. To supply separate colors while preserving the
widget's theme selection, use `light-dark(lightValue, darkValue)`:

```css
:root {
  --zaq-widget-primary: light-dark(#7c3aed, #a78bfa);
  --zaq-widget-on-primary: light-dark(#ffffff, #160b2e);
  --zaq-widget-background: light-dark(#faf8ff, #110d19);
  --zaq-widget-text: light-dark(#221538, #f5f0ff);
  --zaq-widget-muted: light-dark(#756587, #b8aacb);
  --zaq-widget-composer-background: light-dark(#ffffff, #1b1426);
  --zaq-widget-elevated: light-dark(#ede9fe, #302640);
  --zaq-widget-border: light-dark(#ddd6fe, #443456);
}
```

The parent page selects the theme through the existing API:

```js
await window.zaq.widget.updateSettings({ theme: "dark" });
// Supported values: "light", "dark", "auto".
```

The default is `light`. `auto` follows browser appearance. The widget manages
`color-scheme`; do not override it if you want these theme choices to keep working.

## Place the widget inside a div

`stylesheet-url` works with or without `iframe-location-id`:

```html
<div id="zaq-widget" style="width: 100%; height: 600px;"></div>
<script
  src="http://localhost:4000/web_widget/assets/embed.js"
  data-widget-id="13"
  data-token-url="/api/widget-token"
  iframe-location-id="#zaq-widget"
  stylesheet-url="/widget-brand.css"
  defer>
</script>
```

Set the container's dimensions in the **parent page**. The custom stylesheet
controls the widget's contents inside the iframe. Without `iframe-location-id`,
the floating launcher and full-screen conversation behavior remain in effect.

## Scope of customization

These 18 custom properties are the existing styling controls in
[`assets/css/widget.css`](../assets/css/widget.css). There is no CSS-property
allowlist enforced on the stylesheet: normal CSS selectors also work inside the
iframe, but internal class names and markup can change. Prefer the documented
custom properties for brand customization.

There are no dedicated custom properties for message font size, header height,
close-button size, or every individual Markdown element. The radius property does
not affect every component: several activity and Markdown surfaces use fixed
radii. The launcher surroundings remain transparent; the background property
controls the open conversation surface.

CSS does not configure identity, language, widget name, allowed origins or
conversation behavior. Preserve visible focus indicators and readable contrast
when changing colors.
