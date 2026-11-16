# Native Composer test host protocol — 43812503558 / 93dcb653

The Composer test host predated `SharedAccountContext.makeShareScreen(context:params:)`.
Its documented generator command was rerun against the current protocol with the
same six live-member exclusions. The complete generated output differs by exactly
one three-line method (243 generated stubs).

That generated method has the established named fatal-error behavior for an
unprovided harness surface. Existing live composer members are unchanged; no fake
share controller or fallback behavior was introduced. Native compilation remains
part of the next complete IntegrationTests gate.
