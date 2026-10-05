# Hub <-> gateway wire examples

Example messages for the WebSocket between the remote hub in Picky.app and the
gateway (`agentd/src/remote/hub-protocol.ts`). Both sides test against them:

- `agentd/src/remote/hub-protocol.test.ts` parses `hub-to-gateway/*` with the
  gateway's schemas and checks the request bodies in `gateway-to-hub/*`.
- The Swift hub decodes `gateway-to-hub/*` and round-trips `hub-to-gateway/*`
  through its Codable types.

Add a file here when a message type or field changes, then update both sides.
