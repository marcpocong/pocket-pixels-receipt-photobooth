# Operator runbook

Current closure workflow and financial/physical safety boundaries: [Close Session & Continue](close-continue-recovery.md).

1. Enter the existing protected Operator dashboard and open **Commercial Events & Sales**.
2. Confirm `TEST` environment, Worker reachability, device pairing and printer recovery status.
3. Create a draft; configure the detailed local commercial policy (mode, price in integer centavos, 1–10 copies, methods, formats and bounded offline expiry), review, then publish/activate on the server.
4. Pause to stop new checkout, resume to reopen, or end after confirming. Existing paid entitlements remain recoverable.
5. Reports keep **QR Ph Verified**, **QR Ph TEST (excluded)**, **Cash Self-Reported**, and **Cash Physically Counted** separate. No provider fee/payout is inferred.
6. At closeout, count cash physically and save a reason. Corrections append a new audited count. Resolve pending offline sync before treating variance as final.
7. Prepare and share the event-scoped CSV from the operator screen; it is authenticated and never public.
8. For unknown QR, do not accept a replacement cash payment until reconciliation establishes a final nonpaid result. For uncertain print output, inspect the paper and use protected recovery; never auto-reprint.
