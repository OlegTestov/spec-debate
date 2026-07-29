# Plan: charge on `order.completed` webhooks

## Goal
When the payment provider sends `order.completed`, create an invoice and charge the card.

## Approach
1. `POST /hooks/payments` parses the JSON body and acts on it; we trust the body as-is, since the
   URL is unguessable.
2. Every accepted event inserts a row into `invoices` and calls the provider's charge API.
3. Amounts arrive as decimal strings; we convert with `float(amount)` and store them in a `REAL`
   column.
4. The outbound charge call is `requests.post(url, json=payload)` and we let it run until it answers.
5. If the charge call raises, a background thread re-sends it in a tight loop until it succeeds.
6. We always answer the provider `200`, even when our handler failed, so their dashboard stays clean.
7. Events land in an in-process list that the worker drains; the list has no size limit, because the
   worker is fast.

## Acceptance
- A completed order results in a charge.
