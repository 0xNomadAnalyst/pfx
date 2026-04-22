/* ONyc Daily Brief — subscribe modal flow.
 *
 * Handles:
 *   - Hydrating the top subscribe bar from localStorage on page load
 *   - Opening/closing the two modals (subscribe, unsubscribe)
 *   - Focus trap within modals, escape to close, backdrop to close
 *   - Form validation + submission to /api/subscribe
 *   - Unsubscribe confirmation + submission to /api/unsubscribe
 *   - Persisting the subscription to localStorage so the bar reflects state
 *     across page loads
 *
 * No external deps. Vanilla ES6.
 */

(function () {
  "use strict";

  const STORAGE_KEY = "onyc-brief-subscription";

  // ── state helpers ──────────────────────────────────────────────────────
  const loadSub = () => {
    try {
      const raw = localStorage.getItem(STORAGE_KEY);
      return raw ? JSON.parse(raw) : null;
    } catch (_) {
      return null;
    }
  };
  const saveSub = (sub) => localStorage.setItem(STORAGE_KEY, JSON.stringify(sub));
  const clearSub = () => localStorage.removeItem(STORAGE_KEY);

  // ── DOM ────────────────────────────────────────────────────────────────
  const $ = (sel, root) => (root || document).querySelector(sel);
  const $$ = (sel, root) => Array.from((root || document).querySelectorAll(sel));

  const bar            = $("[data-subscribe-bar]");
  const subscribeModal = $('[data-modal="subscribe"]');
  const unsubModal     = $('[data-modal="unsubscribe"]');
  const form           = $("[data-subscribe-form]");

  if (!bar || !subscribeModal || !unsubModal) return;

  // ── bar hydration ──────────────────────────────────────────────────────
  function renderBar() {
    const sub = loadSub();
    const unsubState = $('[data-subscribe-state="unsubscribed"]', bar);
    const subState   = $('[data-subscribe-state="subscribed"]', bar);
    if (sub && sub.email) {
      unsubState.hidden = true;
      subState.hidden = false;
      $("[data-subscribed-channel]",   subState).textContent = sub.slack_channel || "#channel";
      $("[data-subscribed-workspace]", subState).textContent = sub.slack_workspace || "";
      $("[data-subscribed-frequency]", subState).textContent = sub.frequency || "daily";
      $("[data-subscribed-email]",     subState).textContent = sub.email;
    } else {
      unsubState.hidden = false;
      subState.hidden = true;
    }
  }

  // ── focus trap ─────────────────────────────────────────────────────────
  const FOCUSABLE =
    'button:not([disabled]), [href], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';

  let lastTrigger = null;
  let activeModal = null;

  function trapFocus(e) {
    if (!activeModal || e.key !== "Tab") return;
    const focusables = $$(FOCUSABLE, activeModal).filter((el) => !el.closest("[hidden]"));
    if (focusables.length === 0) { e.preventDefault(); return; }
    const first = focusables[0];
    const last  = focusables[focusables.length - 1];
    if (e.shiftKey && document.activeElement === first) {
      e.preventDefault();
      last.focus();
    } else if (!e.shiftKey && document.activeElement === last) {
      e.preventDefault();
      first.focus();
    }
  }

  function onKey(e) {
    if (!activeModal) return;
    if (e.key === "Escape") { e.preventDefault(); closeModal(); }
    else                    { trapFocus(e); }
  }

  function openModal(modal) {
    if (activeModal) closeModal();
    lastTrigger = document.activeElement;
    activeModal = modal;
    modal.hidden = false;
    document.body.style.overflow = "hidden";
    // focus first input (or first focusable) inside the visible step
    const visibleStep = $$("[data-step]", modal).find((s) => !s.hidden);
    const target =
      (visibleStep && $(FOCUSABLE, visibleStep)) ||
      $(".brief-modal", modal);
    if (target) target.focus();
    document.addEventListener("keydown", onKey);
  }

  function closeModal() {
    if (!activeModal) return;
    activeModal.hidden = true;
    // reset each modal to its initial step for next open
    if (activeModal === subscribeModal) {
      showStep(subscribeModal, "form");
    }
    if (activeModal === unsubModal) {
      // cleared on next open — default is no step visible, openModal fills it
      showStep(unsubModal, null);
    }
    activeModal = null;
    document.body.style.overflow = "";
    document.removeEventListener("keydown", onKey);
    if (lastTrigger && typeof lastTrigger.focus === "function") lastTrigger.focus();
  }

  function showStep(modal, name) {
    $$("[data-step]", modal).forEach((s) => {
      // `name === null` hides every step
      s.hidden = name === null ? true : s.dataset.step !== name;
    });
  }

  // ── backdrop + close buttons ───────────────────────────────────────────
  [subscribeModal, unsubModal].forEach((modal) => {
    const backdrop = $("[data-modal-backdrop]", modal);
    if (backdrop) backdrop.addEventListener("click", closeModal);
    $$("[data-close-modal]", modal).forEach((btn) => btn.addEventListener("click", closeModal));
  });

  // ── open triggers ──────────────────────────────────────────────────────
  bar.addEventListener("click", (e) => {
    const openSub = e.target.closest("[data-open-subscribe]");
    const openUnsub = e.target.closest("[data-open-unsubscribe]");
    if (openSub) {
      // Prefill from any prior localStorage entry.
      const prev = loadSub();
      if (prev) {
        form.email.value           = prev.email           || "";
        form.slack_workspace.value = prev.slack_workspace || "";
        form.slack_channel.value   = prev.slack_channel   || "";
        if (prev.frequency && prev.frequency === "daily") {
          const r = form.querySelector('input[name="frequency"][value="daily"]');
          if (r) r.checked = true;
        }
      }
      openModal(subscribeModal);
    }
    if (openUnsub) {
      // "Manage" on the subscribed bar — localStorage is the source of truth
      const sub = loadSub();
      $("[data-unsub-channel]", unsubModal).textContent = (sub && sub.slack_channel) || "#channel";
      // Stage the in-memory "recovered" email so the confirm-button logic
      // can find it even when localStorage isn't populated.
      recoveredEmail = (sub && sub.email) || null;
      showStep(unsubModal, "confirm");
      openModal(unsubModal);
    }
    const openRecover = e.target.closest("[data-open-recover]");
    if (openRecover) {
      // "Already subscribed? Manage by email" on the unsubscribed bar — no
      // localStorage; user enters their email to look up their active row.
      recoveredEmail = null;
      const emailInput = $('[data-recover-form] [name="recover_email"]', unsubModal);
      if (emailInput) emailInput.value = "";
      setError("recover-email", "");
      showStep(unsubModal, "lookup");
      openModal(unsubModal);
    }
  });

  // Carries the email that the confirm button will submit to /api/unsubscribe.
  // Sourced from either localStorage (classic Manage) or a successful lookup.
  let recoveredEmail = null;

  // "Try a different email" → back to lookup step
  const recoverBackBtn = $("[data-recover-back]", unsubModal);
  if (recoverBackBtn) {
    recoverBackBtn.addEventListener("click", () => {
      const emailInput = $('[data-recover-form] [name="recover_email"]', unsubModal);
      if (emailInput) { emailInput.value = ""; emailInput.focus(); }
      setError("recover-email", "");
      showStep(unsubModal, "lookup");
    });
  }

  // Recover-by-email submit
  const recoverForm = $("[data-recover-form]", unsubModal);
  if (recoverForm) {
    recoverForm.addEventListener("submit", async (e) => {
      e.preventDefault();
      const email = recoverForm.recover_email.value.trim().toLowerCase();
      if (!EMAIL_RE.test(email)) {
        setError("recover-email", "enter a valid email address");
        return;
      }
      setError("recover-email", "");
      const submitBtn = $("[data-recover-submit]", recoverForm);
      submitBtn.disabled = true;
      submitBtn.textContent = "Looking up…";
      try {
        const resp = await fetch(`/api/subscription?email=${encodeURIComponent(email)}`);
        if (resp.status === 404) {
          $("[data-not-found-email]", unsubModal).textContent = email;
          showStep(unsubModal, "not_found");
          return;
        }
        if (!resp.ok) {
          setError("recover-email", "lookup failed — please try again");
          return;
        }
        const data = await resp.json();
        recoveredEmail = data.email;
        $("[data-unsub-channel]", unsubModal).textContent = data.slack_channel || "#channel";
        showStep(unsubModal, "confirm");
      } catch (err) {
        console.error(err);
        setError("recover-email", "network error — please try again");
      } finally {
        submitBtn.disabled = false;
        submitBtn.textContent = "Continue";
      }
    });
  }

  // ── form validation + submit ───────────────────────────────────────────
  const EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;

  const FIELD_TO_INPUT = {
    email:           "email",
    workspace:       "slack_workspace",
    channel:         "slack_channel",
    "recover-email": "recover_email",
  };

  // Field → owning form. `null` means the function picks up the right form
  // by querying `document` instead.
  function setError(field, msg, root) {
    const scope = root || document;
    const hint  = scope.querySelector(`[data-error-${field}]`);
    const input = scope.querySelector(`[name="${FIELD_TO_INPUT[field]}"]`);
    if (input) input.setAttribute("aria-invalid", msg ? "true" : "false");
    if (hint) {
      if (msg) hint.textContent = msg;
      hint.hidden = !msg;
    }
  }

  function validate() {
    let ok = true;
    const email = form.email.value.trim();
    const ws    = form.slack_workspace.value.trim();
    const ch    = form.slack_channel.value.trim();
    if (!EMAIL_RE.test(email)) { setError("email",     "enter a valid email address"); ok = false; } else setError("email",     "");
    if (!ws)                   { setError("workspace", "workspace is required");       ok = false; } else setError("workspace", "");
    if (!ch)                   { setError("channel",   "channel is required");         ok = false; } else setError("channel",   "");
    return ok;
  }

  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    if (!validate()) return;
    const submitBtn = $("[data-submit]", form);
    submitBtn.disabled = true;
    submitBtn.textContent = "Subscribing…";
    try {
      const freq = (form.querySelector('input[name="frequency"]:checked') || {}).value || "daily";
      const body = {
        email:           form.email.value.trim().toLowerCase(),
        slack_workspace: form.slack_workspace.value.trim(),
        slack_channel:   form.slack_channel.value.trim(),
        frequency:       freq,
      };
      const resp = await fetch("/api/subscribe", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
      if (!resp.ok) {
        const err = await resp.json().catch(() => ({}));
        alert("Subscribe failed: " + (err.error || resp.status));
        return;
      }
      const data = await resp.json();
      saveSub({
        email:           data.email,
        slack_workspace: data.slack_workspace,
        slack_channel:   data.slack_channel,
        frequency:       data.frequency,
      });
      // populate success step
      $("[data-success-channel]",   subscribeModal).textContent = data.slack_channel;
      $("[data-success-workspace]", subscribeModal).textContent = data.slack_workspace;
      showStep(subscribeModal, "success");
      renderBar();
    } catch (err) {
      console.error(err);
      alert("Subscribe failed: network error");
    } finally {
      submitBtn.disabled = false;
      submitBtn.textContent = "Subscribe";
    }
  });

  // ── unsubscribe confirm ────────────────────────────────────────────────
  $("[data-confirm-unsubscribe]", unsubModal).addEventListener("click", async () => {
    // Prefer the recovery-flow email if set; fall back to localStorage.
    const sub = loadSub();
    const email = recoveredEmail || (sub && sub.email) || null;
    if (!email) { closeModal(); return; }
    const btn = $("[data-confirm-unsubscribe]", unsubModal);
    btn.disabled = true;
    btn.textContent = "Unsubscribing…";
    try {
      const resp = await fetch("/api/unsubscribe", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ email: email }),
      });
      if (!resp.ok) {
        alert("Unsubscribe failed: " + resp.status);
        return;
      }
      // Always clear any local trace on success — even if the unsubscribed
      // email did not match the localStorage one (which can happen if the
      // user manages someone else's or their own fresh-browser subscription).
      if (sub && sub.email === email) clearSub();
      recoveredEmail = null;
      renderBar();
      closeModal();
    } catch (err) {
      console.error(err);
      alert("Unsubscribe failed: network error");
    } finally {
      btn.disabled = false;
      btn.textContent = "Unsubscribe";
    }
  });

  // initial paint
  renderBar();
})();
