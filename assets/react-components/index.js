import { Simple } from "./simple";
import { LinkExample } from "./link-example";
import { Link } from "live_react";
import { createElement, lazy, Suspense } from "react";

const LazyWebWidget = lazy(() =>
  import("./web-widget").then(({ WebWidget }) => ({ default: WebWidget })),
);

function WebWidget(props) {
  return createElement(
    Suspense,
    { fallback: createElement("p", { role: "status" }, "Loading assistant…") },
    createElement(LazyWebWidget, props),
  );
}

export default {
  WebWidget,
  Simple,
  LinkExample,
  Link,
};
