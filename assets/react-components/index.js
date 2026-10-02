import { Simple } from "./simple";
import { LinkExample } from "./link-example";
import { Link } from "live_react";
import { createElement, lazy, Suspense } from "react";

const LazyAssistantUI = lazy(() =>
  import("./assistant-ui").then(({ AssistantUI }) => ({ default: AssistantUI })),
);

function AssistantUI(props) {
  return createElement(
    Suspense,
    { fallback: createElement("p", { role: "status" }, "Loading assistant…") },
    createElement(LazyAssistantUI, props),
  );
}

export default {
  AssistantUI,
  Simple,
  LinkExample,
  Link,
};
