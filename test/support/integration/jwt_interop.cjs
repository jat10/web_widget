// Independent RFC 7515/7518 interoperability fixture, not a production token endpoint.
const { createHmac, timingSafeEqual } = require("node:crypto");
const key = process.env.WIDGET_TEST_KEY;
const encode = value => Buffer.from(JSON.stringify(value), "utf8").toString("base64url");
if (process.env.WIDGET_TEST_TOKEN) {
  const [header, payload, signature] = process.env.WIDGET_TEST_TOKEN.split(".");
  const expected = createHmac("sha256", key).update(`${header}.${payload}`).digest();
  const actual = Buffer.from(signature, "base64url");
  if (expected.length !== actual.length || !timingSafeEqual(expected, actual)) process.exit(1);
  if (JSON.parse(Buffer.from(header, "base64url")).alg !== "HS256") process.exit(1);
  process.stdout.write(Buffer.from(payload, "base64url"));
} else {
  const payload = JSON.parse(process.env.WIDGET_TEST_CLAIMS);
  const input = `${encode({ alg: "HS256", typ: "JWT" })}.${encode(payload)}`;
  process.stdout.write(`${input}.${createHmac("sha256", key).update(input).digest("base64url")}`);
}
