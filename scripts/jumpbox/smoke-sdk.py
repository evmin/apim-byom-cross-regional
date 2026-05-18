#!/usr/bin/env python3
"""
smoke-sdk.py — spec-aligned Foundry agents-runtime smoke.

⚠️  EXPECTED_FAIL_PLATFORM_ISSUE
    At the time the fdev demo was finalised, the Foundry agents runtime
    consistently returned `server_error` (~3s) on `create_thread_and_process_run`
    for VNet-injected accounts in every agent region we tried (NEU/WE/EUS2/FRC
    and finally CHN). The failure happens BEFORE APIM is contacted (no traffic
    in APIM gateway logs), suggesting the managed Container Apps Environment
    that the runtime bootstraps in the SAL'd subnet fails internally. This is a
    Microsoft platform-side limitation — none of the agent-side RBAC, agent
    identity, or model deployment grants we tried fixed it.

    The validation suite (jumpbox-smoke.sh) therefore tolerates a FAIL here
    while still attempting the test for honest disclosure. The spec-aligned
    cross-region BYOM path is exercised separately by smoke-bridge.sh
    (jumpbox UAMI → APIM PE → SC AOAI), which proves the private-network
    plumbing works end to end without the agents runtime in front.

    Once Microsoft fixes the agents runtime / managed CAE bootstrap for
    network-injected Foundry accounts, this smoke is expected to PASS and the
    EXPECTED_FAIL exception in jumpbox-smoke.sh should be removed.

Path (when working):
    jumpbox → AgentsClient (project endpoint) → ephemeral Foundry agent using
    `apim-byom` connection → APIM (token issued server-side by project MI) →
    SC AOAI → reply.

Why agents (not direct openai client):
    Foundry agents are first-class consumers of project connections. When an
    agent run picks model `<connection-name>/<deployment-name>`, Foundry maps
    that to the apim-byom connection (`isDefault=true`, category=ApiManagement,
    deployments=...), signs the upstream APIM call with the *project* MI, and
    APIM accepts it. This mirrors the real production code path (an agent app
    calling its own model), so a PASS here is a true validation of the
    end-to-end stack.

Authentication:
    ManagedIdentityCredential bound to the jumpbox UAMI. The UAMI must have
    *Azure AI Developer* on the agent project (DJ-005), so it can create + run
    agents.

Expects (env, set by cloud-init's /etc/profile.d/mreg-validate.sh):
  AGENT_PROJECT_ENDPOINT  — https://<account>.services.ai.azure.com/api/projects/<project>
  MODEL_DEPLOYMENT_NAME   — e.g. gpt-5.4-nano
  AZURE_CLIENT_ID         — (optional) UAMI clientId for the credential

Exit code: 0 on PASS, non-zero on FAIL. Prints latency.
"""

from __future__ import annotations

import os
import sys
import time

EXIT_OK = 0
EXIT_CONFIG = 2
EXIT_AUTH = 3
EXIT_HTTP = 4
EXIT_EMPTY = 5


def _strip_dup_scheme(url: str) -> str:
    # Defensive: the IaC fix for the duplicate-https:// bug lands in the same
    # session, but operators may have a stale env from before the fix.
    while url.startswith("https://https://"):
        url = url[len("https://") :]
    return url


def main() -> int:
    endpoint = _strip_dup_scheme(os.environ.get("AGENT_PROJECT_ENDPOINT", "").strip())
    deployment = os.environ.get("MODEL_DEPLOYMENT_NAME", "").strip()
    connection = os.environ.get("FOUNDRY_CONNECTION_NAME", "apim-byom").strip()
    if not endpoint or not deployment:
        print(
            "smoke-sdk: AGENT_PROJECT_ENDPOINT and MODEL_DEPLOYMENT_NAME are required",
            file=sys.stderr,
        )
        return EXIT_CONFIG

    # Per the architecture spec, agents reference a BYOM model via the connection
    # by name: "<connection-name>/<deployment-name>". The Foundry agent runtime
    # looks the deployment up in the named connection and routes the upstream
    # call (token signed by the *project* MI) to APIM.
    model_ref = f"{connection}/{deployment}"

    print(f"smoke-sdk: endpoint   = {endpoint}")
    print(f"smoke-sdk: connection = {connection}")
    print(f"smoke-sdk: deployment = {deployment}")
    print(f"smoke-sdk: model_ref  = {model_ref}")

    try:
        from azure.identity import ManagedIdentityCredential
        from azure.ai.agents import AgentsClient
        from azure.ai.agents.models import ListSortOrder, MessageRole
    except Exception as exc:  # pragma: no cover - covered by bootstrap.sh
        print(f"smoke-sdk: ImportError — {exc}", file=sys.stderr)
        return EXIT_CONFIG

    client_id = os.environ.get("AZURE_CLIENT_ID", "").strip() or None
    cred = ManagedIdentityCredential(client_id=client_id) if client_id else ManagedIdentityCredential()

    try:
        agents = AgentsClient(endpoint=endpoint, credential=cred)
    except Exception as exc:
        print(f"smoke-sdk: AgentsClient init failed — {exc}", file=sys.stderr)
        return EXIT_AUTH

    agent_id = None
    try:
        # 1. Create an ephemeral smoke agent backed by the apim-byom-routed model.
        agent = agents.create_agent(
            model=model_ref,
            name="mreg-smoke-probe",
            instructions="You are a deployment smoke probe. Reply with the single word OK.",
        )
        agent_id = agent.id
        print(f"smoke-sdk: agent created id={agent_id}")

        # 2. Run synchronously — create_thread_and_process_run polls until terminal.
        started = time.monotonic()
        run = agents.create_thread_and_process_run(
            agent_id=agent_id,
            thread={
                "messages": [{"role": "user", "content": "Reply with the single word OK."}],
            },
        )
        elapsed_ms = (time.monotonic() - started) * 1000

        if run.status != "completed":
            err = getattr(run, "last_error", None)
            print(
                f"smoke-sdk: run terminated status={run.status} after {elapsed_ms:.0f} ms — "
                f"last_error={err}",
                file=sys.stderr,
            )
            return EXIT_HTTP

        # 3. Read back the assistant's reply.
        msgs = list(
            agents.messages.list(
                thread_id=run.thread_id,
                order=ListSortOrder.ASCENDING,
            )
        )
        reply = None
        for m in msgs:
            if m.role == MessageRole.AGENT and getattr(m, "text_messages", None):
                reply = m.text_messages[-1].text.value
                break

        if not reply:
            print(
                f"smoke-sdk: completed but no assistant reply after {elapsed_ms:.0f} ms",
                file=sys.stderr,
            )
            return EXIT_EMPTY

        print(f"smoke-sdk: PASS in {elapsed_ms:.0f} ms — reply='{reply.strip()}'")
        return EXIT_OK
    except Exception as exc:
        print(f"smoke-sdk: agent run raised — {exc}", file=sys.stderr)
        return EXIT_HTTP
    finally:
        # Always try to clean up the ephemeral agent, regardless of run outcome.
        if agent_id is not None:
            try:
                agents.delete_agent(agent_id)
            except Exception:
                pass


if __name__ == "__main__":
    sys.exit(main())
