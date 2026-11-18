(() => {
  "use strict";

  const state = {
    mode: "raw", // "raw" | "json" | "barcode" | "pdf" | "redact" | "ai"
    script: "latin",
    showOverlays: true,
    overlayLevel: "lines", // "blocks" | "lines"
    compareView: "after", // "after" | "before" | "split"
    splitPercent: 50,
    pdfOptions: {
      pageFormat: "a4",
      maxSizeMb: "",
      enhance: true,
    },
    redactOptions: {
      presets: ["ids", "contacts", "addresses", "faces"],
      keepLast4: false,
      enhance: false,
      outputFormat: "image",
    },
    aiOptions: {
      task: "table", // "table" | "receipt" | "vcard" | "ocr" | "custom"
      customPrompt: "",
      jsonMode: false,
    },
    batch: [],
    activeId: null,
    selectedBoxId: null,
    selectedBoxText: "",
    queue: [],
    isQueueRunning: false,
    processingKey: null,
  };

  const els = {
    serverStatusDot: document.getElementById("serverStatusDot"),
    serverStatusText: document.getElementById("serverStatusText"),
    modeBtns: Array.from(document.querySelectorAll(".mode-btn")),
    scriptPickerWrap: document.getElementById("scriptPickerWrap"),
    scriptSelect: document.getElementById("scriptSelect"),
    downloadBatchZipBtn: document.getElementById("downloadBatchZipBtn"),
    clearBatchBtn: document.getElementById("clearBatchBtn"),
    docControlsBar: document.getElementById("docControlsBar"),
    pdfControlsGroup: document.getElementById("pdfControlsGroup"),
    pdfPageFormatSelect: document.getElementById("pdfPageFormatSelect"),
    pdfMaxSizeSelect: document.getElementById("pdfMaxSizeSelect"),
    pdfEnhanceToggle: document.getElementById("pdfEnhanceToggle"),
    redactControlsGroup: document.getElementById("redactControlsGroup"),
    presetCheckboxes: Array.from(
      document.querySelectorAll("#redactControlsGroup input[data-preset]")
    ),
    keepLast4Toggle: document.getElementById("keepLast4Toggle"),
    redactEnhanceToggle: document.getElementById("redactEnhanceToggle"),
    redactDownloadFormat: document.getElementById("redactDownloadFormat"),
    aiControlsGroup: document.getElementById("aiControlsGroup"),
    aiTaskSelect: document.getElementById("aiTaskSelect"),
    aiPromptInput: document.getElementById("aiPromptInput"),
    aiJsonModeToggle: document.getElementById("aiJsonModeToggle"),
    aiRunBtn: document.getElementById("aiRunBtn"),
    dropZone: document.getElementById("dropZone"),
    fileInput: document.getElementById("fileInput"),
    batchStrip: document.getElementById("batchStrip"),
    previewHeading: document.getElementById("previewHeading"),
    dimensionsChip: document.getElementById("dimensionsChip"),
    compareSwitchGroup: document.getElementById("compareSwitchGroup"),
    compareBtns: Array.from(
      document.querySelectorAll("#compareSwitchGroup .seg-btn")
    ),
    overlayToggleWrap: document.getElementById("overlayToggleWrap"),
    overlayToggle: document.getElementById("overlayToggle"),
    overlayLevelSelect: document.getElementById("overlayLevelSelect"),
    imageEmptyState: document.getElementById("imageEmptyState"),
    pdfPendingState: document.getElementById("pdfPendingState"),
    pdfPendingTitle: document.getElementById("pdfPendingTitle"),
    pdfPendingHint: document.getElementById("pdfPendingHint"),
    canvasWrapper: document.getElementById("canvasWrapper"),
    previewImage: document.getElementById("previewImage"),
    beforeCompareImage: document.getElementById("beforeCompareImage"),
    compareDivider: document.getElementById("compareDivider"),
    overlaySvg: document.getElementById("overlaySvg"),
    compareSliderBar: document.getElementById("compareSliderBar"),
    compareSlider: document.getElementById("compareSlider"),
    compareReadout: document.getElementById("compareReadout"),
    hoverInspector: document.getElementById("hoverInspector"),
    inspectorTag: document.getElementById("inspectorTag"),
    inspectorText: document.getElementById("inspectorText"),
    copyBoxBtn: document.getElementById("copyBoxBtn"),
    clearBoxBtn: document.getElementById("clearBoxBtn"),
    outputHeading: document.getElementById("outputHeading"),
    latencyChip: document.getElementById("latencyChip"),
    summaryChip: document.getElementById("summaryChip"),
    copyBtn: document.getElementById("copyBtn"),
    downloadBtn: document.getElementById("downloadBtn"),
    outputEmptyState: document.getElementById("outputEmptyState"),
    docSummaryCard: document.getElementById("docSummaryCard"),
    rawTextLines: document.getElementById("rawTextLines"),
    barcodeCards: document.getElementById("barcodeCards"),
    outputPre: document.getElementById("outputPre"),
  };

  const DEFAULT_INSPECTOR_HINT = "Hover or click a bounding box to inspect or copy";

  function getActiveItem() {
    return state.batch.find((item) => item.id === state.activeId) || null;
  }

  function isPdfFile(file) {
    if (!file) return false;
    return (
      file.type === "application/pdf" ||
      /\.pdf$/i.test(file.name || "")
    );
  }

  function isDocMode(mode = state.mode) {
    return mode === "pdf" || mode === "redact";
  }

  function supportsPdfInput(mode = state.mode) {
    return isDocMode(mode) || mode === "ai";
  }

  function itemHasResultForMode(item, mode = state.mode) {
    if (!item) return false;
    if (mode === "barcode") return Boolean(item.barcodeData);
    if (mode === "pdf") return Boolean(item.pdfData);
    if (mode === "redact") return Boolean(item.redactData);
    if (mode === "ai") return Boolean(item.aiData);
    return Boolean(item.ocrData);
  }

  async function pollServerStatus() {
    try {
      const res = await fetch("/v1/status", { cache: "no-store" });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      els.serverStatusDot.className = "dot online";
      const battery =
        data.telemetry && typeof data.telemetry.battery_level === "number"
          ? ` · ${data.telemetry.battery_level}%`
          : "";
      const host = data.hostname || window.location.host;
      els.serverStatusText.textContent = `${host}${battery}`;
    } catch (_) {
      els.serverStatusDot.className = "dot offline";
      els.serverStatusText.textContent = "Server unreachable";
    }
  }

  function resetInspector() {
    els.inspectorTag.textContent = "Region";
    els.inspectorText.textContent = DEFAULT_INSPECTOR_HINT;
    els.inspectorText.classList.add("muted");
    els.copyBoxBtn.classList.add("hidden");
    els.clearBoxBtn.classList.add("hidden");
  }

  function clearBoxSelection() {
    state.selectedBoxId = null;
    state.selectedBoxText = "";
    resetInspector();
    els.overlaySvg.querySelectorAll(".bbox-rect.active").forEach((el) => {
      el.classList.remove("active");
    });
    document
      .querySelectorAll(".text-segment.active, .barcode-card.active")
      .forEach((el) => {
        el.classList.remove("active");
      });
  }

  function showInspector(tag, text, isLocked) {
    els.inspectorTag.textContent = tag;
    els.inspectorText.textContent = text;
    els.inspectorText.classList.remove("muted");
    els.copyBoxBtn.classList.toggle("hidden", !isLocked);
    els.clearBoxBtn.classList.toggle("hidden", !isLocked);
  }

  function selectBox(boxId, text, scrollRight = true) {
    state.selectedBoxId = boxId;
    state.selectedBoxText = text;

    els.overlaySvg.querySelectorAll(".bbox-rect").forEach((rect) => {
      rect.classList.toggle("active", rect.dataset.boxId === boxId);
    });

    const targets = document.querySelectorAll(".text-segment, .barcode-card");
    targets.forEach((el) => {
      const match = el.dataset.boxId === boxId;
      el.classList.toggle("active", match);
      if (match && scrollRight) {
        el.scrollIntoView({ block: "nearest", behavior: "smooth" });
      }
    });

    showInspector("Selected", text, true);
  }

  function setHoveredBox(boxId, text) {
    document.querySelectorAll(".text-segment.hovered").forEach((el) => {
      el.classList.remove("hovered");
    });
    if (boxId) {
      const seg = document.querySelector(
        `.text-segment[data-box-id="${CSS.escape(boxId)}"], .barcode-card[data-box-id="${CSS.escape(boxId)}"]`
      );
      if (seg) seg.classList.add("hovered");
      if (!state.selectedBoxId) {
        showInspector("Hover", text, false);
      }
    } else if (!state.selectedBoxId) {
      resetInspector();
    }
  }

  function updateToolbarVisibility() {
    const mode = state.mode;
    const isBarcode = mode === "barcode";
    const isPdf = mode === "pdf";
    const isRedact = mode === "redact";
    const isAi = mode === "ai";
    const inDocMode = isPdf || isRedact;

    els.scriptPickerWrap.classList.toggle("hidden", isBarcode);
    els.overlayToggleWrap.classList.toggle("hidden", isPdf || isAi);
    els.overlayLevelSelect.classList.toggle(
      "hidden",
      isBarcode || isPdf || isRedact || isAi
    );

    els.docControlsBar.classList.toggle("hidden", !inDocMode && !isAi);
    els.pdfControlsGroup.classList.toggle("hidden", !isPdf);
    els.redactControlsGroup.classList.toggle("hidden", !isRedact);
    els.aiControlsGroup.classList.toggle("hidden", !isAi);
    els.downloadBatchZipBtn.classList.toggle("hidden", !inDocMode);

    const isCustomAi = isAi && state.aiOptions.task === "custom";
    els.aiPromptInput.classList.toggle("hidden", !isCustomAi);
    els.aiRunBtn.classList.toggle("hidden", !isCustomAi);
    if (els.hoverInspector) {
      els.hoverInspector.classList.toggle("hidden", isPdf || isAi);
    }

    if (mode === "raw") {
      els.previewHeading.textContent = "Image & Bounding Boxes";
      els.outputHeading.textContent = "Extracted Text";
    } else if (mode === "json") {
      els.previewHeading.textContent = "Image & Bounding Boxes";
      els.outputHeading.textContent = "Structured JSON";
    } else if (mode === "barcode") {
      els.previewHeading.textContent = "Image & Barcode Regions";
      els.outputHeading.textContent = "Barcode Scan";
    } else if (mode === "pdf") {
      els.previewHeading.textContent = "Page Cleanup & Preview";
      els.outputHeading.textContent = "Searchable PDF Output";
    } else if (mode === "redact") {
      els.previewHeading.textContent = "Before / After Redaction";
      els.outputHeading.textContent = "PII Redaction Audit";
    } else {
      els.previewHeading.textContent = "Input Document";
      els.outputHeading.textContent = "OpenAI Vision Output";
    }

    updateBatchZipButton();
  }

  function updateBatchZipButton() {
    const readyCount = state.batch.length;
    els.downloadBatchZipBtn.disabled =
      readyCount === 0 || state.isQueueRunning;
    els.downloadBatchZipBtn.textContent =
      readyCount > 1
        ? `Download Batch .zip (${readyCount})`
        : "Download Batch .zip";
  }

  function setMode(nextMode) {
    if (state.mode === nextMode) return;
    state.mode = nextMode;
    clearBoxSelection();

    els.modeBtns.forEach((btn) => {
      const active = btn.dataset.mode === nextMode;
      btn.classList.toggle("active", active);
      btn.setAttribute("aria-selected", String(active));
      if (active && typeof btn.scrollIntoView === "function") {
        btn.scrollIntoView({ block: "nearest", inline: "nearest" });
      }
    });

    updateToolbarVisibility();

    const activeItem = getActiveItem();
    if (activeItem) {
      if (!itemHasResultForMode(activeItem, nextMode) && !activeItem.error) {
        enqueueItem(activeItem);
      } else {
        renderActiveItem();
      }
    } else {
      renderActiveItem();
    }
  }

  function setCompareView(view) {
    state.compareView = view;
    els.compareBtns.forEach((btn) => {
      const active = btn.dataset.compare === view;
      btn.classList.toggle("active", active);
      btn.setAttribute("aria-pressed", String(active));
    });
    renderActiveItem();
  }

  function syncSliderVisuals() {
    const slider = els.compareSlider;
    if (!slider) return;
    const val = Number(slider.value);
    state.splitPercent = Number.isFinite(val) ? val : 50;
    slider.style.setProperty("--attr-min", slider.min || "0");
    slider.style.setProperty("--attr-max", slider.max || "100");
    slider.style.setProperty("--control-value", String(state.splitPercent));
    slider.setAttribute("aria-valuetext", `${state.splitPercent}% split comparison`);
    els.compareReadout.textContent = `${state.splitPercent}%`;
    updateSplitClip();
  }

  function updateSplitClip() {
    if (state.compareView !== "split") return;
    const pct = state.splitPercent;
    els.beforeCompareImage.style.clipPath = `inset(0 ${100 - pct}% 0 0)`;

    const img = els.previewImage;
    if (img.clientWidth > 0 && img.clientHeight > 0) {
      els.compareDivider.style.left = `${
        img.offsetLeft + (img.clientWidth * pct) / 100
      }px`;
      els.compareDivider.style.top = `${img.offsetTop}px`;
      els.compareDivider.style.height = `${img.clientHeight}px`;
    }
  }

  function addFiles(fileList) {
    const validFiles = Array.from(fileList || []).filter(
      (f) =>
        f.type.startsWith("image/") ||
        isPdfFile(f) ||
        /\.(png|jpe?g|webp|bmp|gif|pdf)$/i.test(f.name || "")
    );
    if (validFiles.length === 0) return;

    const allDroppedArePdfs = validFiles.every((f) => isPdfFile(f));
    if (allDroppedArePdfs && !supportsPdfInput(state.mode)) {
      setMode("pdf");
    }

    const newItems = validFiles.map((file, idx) => {
      const pdf = isPdfFile(file);
      return {
        id: `${Date.now()}-${Math.random().toString(36).slice(2, 8)}-${idx}`,
        file,
        isPdf: pdf,
        url: pdf ? null : URL.createObjectURL(file),
        status: "queued",
        ocrData: null,
        barcodeData: null,
        pdfData: null,
        redactData: null,
        aiData: null,
        error: null,
      };
    });

    state.batch.push(...newItems);
    if (!state.activeId && newItems.length > 0) {
      state.activeId = newItems[0].id;
    } else if (newItems.length === 1) {
      state.activeId = newItems[0].id;
    }

    clearBoxSelection();
    els.clearBatchBtn.disabled = state.batch.length === 0;
    els.dropZone.classList.toggle("compact", state.batch.length > 0);
    renderBatchStrip();
    renderActiveItem();

    newItems.forEach((item) => {
      enqueueItem(item);
    });
  }

  function enqueueItem(item) {
    if (!item) return;
    const key = `${item.id}:${state.mode}`;
    if (state.processingKey === key) return;
    if (!state.queue.includes(item.id)) {
      item.status = "queued";
      item.error = null;
      state.queue.push(item.id);
    }
    renderBatchStrip();
    if (!state.isQueueRunning) {
      drainQueue();
    }
  }

  function enqueueAllBatchItems(prioritizeActive = true) {
    if (state.batch.length === 0) return;
    const ordered = [];
    if (prioritizeActive && state.activeId) {
      const active = getActiveItem();
      if (active) ordered.push(active);
    }
    for (const item of state.batch) {
      if (!ordered.includes(item)) ordered.push(item);
    }
    ordered.forEach((item) => {
      item.status = "queued";
      item.error = null;
      if (!state.queue.includes(item.id)) {
        state.queue.push(item.id);
      }
    });
    renderBatchStrip();
    renderActiveItem();
    if (!state.isQueueRunning) {
      drainQueue();
    }
  }

  async function drainQueue() {
    if (state.isQueueRunning) return;
    state.isQueueRunning = true;
    updateBatchZipButton();

    try {
      while (state.queue.length > 0) {
        const nextId = state.queue.shift();
        const item = state.batch.find((entry) => entry.id === nextId);
        if (!item) continue;
        await processItem(item);
      }
    } finally {
      state.isQueueRunning = false;
      updateBatchZipButton();
      renderBatchStrip();
    }
  }

  function fileToDataUri(file) {
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolve(String(reader.result || ""));
      reader.onerror = () =>
        reject(new Error("Failed to read file as base64 data URI."));
      reader.readAsDataURL(file);
    });
  }

  function buildAiRequestSpec() {
    const task = state.aiOptions.task;
    if (task === "table") {
      return {
        model: "local-table",
        prompt: "Extract any table in this document as clean Markdown.",
      };
    }
    if (task === "receipt") {
      return {
        model: "local-structured",
        prompt:
          "Parse this receipt or invoice into structured JSON fields and line items.",
      };
    }
    if (task === "vcard") {
      return {
        model: "local-vcard",
        prompt: "Extract business card contact information as a vCard.",
      };
    }
    if (task === "custom") {
      return {
        model: "local-edge-vision",
        prompt:
          state.aiOptions.customPrompt.trim() ||
          "Extract all readable text cleanly.",
      };
    }
    return {
      model: "local-ocr",
      prompt: "Extract all readable text cleanly.",
    };
  }

  async function processItem(item) {
    const mode = state.mode;
    if (item.isPdf && !supportsPdfInput(mode)) {
      item.status = "done";
      item.error = null;
      renderBatchStrip();
      if (item.id === state.activeId) renderActiveItem();
      return;
    }

    if (mode === "redact" && state.redactOptions.presets.length === 0) {
      item.status = "error";
      item.error = "Select at least one PII redaction preset.";
      renderBatchStrip();
      if (item.id === state.activeId) renderActiveItem();
      return;
    }

    item.status = "processing";
    item.error = null;
    state.processingKey = `${item.id}:${mode}`;
    renderBatchStrip();
    if (item.id === state.activeId) renderActiveItem();

    if (mode === "ai") {
      try {
        const dataUri = await fileToDataUri(item.file);
        const spec = buildAiRequestSpec();
        const requestBody = {
          model: spec.model,
          script: state.script,
          messages: [
            {
              role: "user",
              content: [
                { type: "text", text: spec.prompt },
                { type: "image_url", image_url: { url: dataUri } },
              ],
            },
          ],
        };
        if (state.aiOptions.jsonMode) {
          requestBody.response_format = { type: "json_object" };
        }

        const response = await fetch("/v1/chat/completions", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify(requestBody),
        });
        const payload = await response.json();
        if (!response.ok) {
          const errMsg =
            (payload.error && payload.error.message) ||
            payload.message ||
            payload.error ||
            `HTTP ${response.status}`;
          throw new Error(String(errMsg));
        }

        item.aiData = payload;
        item.status = "done";
      } catch (err) {
        item.status = "error";
        item.error = err instanceof Error ? err.message : String(err);
      }

      renderBatchStrip();
      if (item.id === state.activeId) {
        renderActiveItem();
      }
      state.processingKey = null;
      return;
    }

    const formData = new FormData();
    const fieldName = isDocMode(mode) ? "file" : "image";
    const fallbackName = item.isPdf ? "document.pdf" : "image.png";
    formData.append(fieldName, item.file, item.file.name || fallbackName);

    let endpoint = "";
    if (mode === "barcode") {
      endpoint = "/v1/barcode";
    } else if (mode === "pdf") {
      const qs = new URLSearchParams({
        response_format: "json",
        script: state.script,
        page_format: state.pdfOptions.pageFormat,
        enhance: String(state.pdfOptions.enhance),
      });
      if (state.pdfOptions.maxSizeMb) {
        qs.set("max_size_mb", state.pdfOptions.maxSizeMb);
      }
      endpoint = `/v1/doc/searchable-pdf?${qs.toString()}`;
    } else if (mode === "redact") {
      const qs = new URLSearchParams({
        output_format: "json",
        script: state.script,
        presets: state.redactOptions.presets.join(","),
        keep_last_4: String(state.redactOptions.keepLast4),
        enhance: String(state.redactOptions.enhance),
      });
      endpoint = `/v1/doc/redact?${qs.toString()}`;
    } else {
      endpoint = `/v1/ocr?script=${encodeURIComponent(state.script)}`;
    }

    try {
      const response = await fetch(endpoint, {
        method: "POST",
        body: formData,
      });
      const payload = await response.json();
      if (!response.ok) {
        throw new Error(
          payload.message || payload.error || `HTTP ${response.status}`
        );
      }

      if (mode === "barcode") {
        item.barcodeData = payload;
      } else if (mode === "pdf") {
        item.pdfData = payload;
      } else if (mode === "redact") {
        item.redactData = payload;
      } else {
        item.ocrData = payload;
      }
      item.status = "done";
    } catch (err) {
      item.status = "error";
      item.error = err instanceof Error ? err.message : String(err);
    } finally {
      state.processingKey = null;
    }

    renderBatchStrip();
    if (item.id === state.activeId) {
      renderActiveItem();
    }
  }

  function resolveItemThumbnailUrl(item) {
    if (item.redactData && item.redactData.after_image_base64) {
      return `data:image/png;base64,${item.redactData.after_image_base64}`;
    }
    if (item.pdfData && item.pdfData.after_image_base64) {
      return `data:image/png;base64,${item.pdfData.after_image_base64}`;
    }
    return item.url;
  }

  function renderBatchStrip() {
    if (state.batch.length <= 1) {
      els.batchStrip.classList.add("hidden");
      els.batchStrip.innerHTML = "";
      return;
    }

    els.batchStrip.classList.remove("hidden");
    els.batchStrip.innerHTML = "";

    state.batch.forEach((item) => {
      const card = document.createElement("button");
      card.type = "button";
      card.className = `batch-item${item.id === state.activeId ? " active" : ""}`;
      card.addEventListener("click", () => {
        state.activeId = item.id;
        clearBoxSelection();
        renderBatchStrip();
        const active = getActiveItem();
        if (active) {
          if (!itemHasResultForMode(active) && !active.error) {
            enqueueItem(active);
          } else {
            renderActiveItem();
          }
        }
      });

      const thumbUrl = resolveItemThumbnailUrl(item);
      let thumbEl;
      if (thumbUrl) {
        thumbEl = document.createElement("img");
        thumbEl.className = "batch-thumb";
        thumbEl.src = thumbUrl;
        thumbEl.alt = item.file.name || "Batch preview";
      } else {
        thumbEl = document.createElement("div");
        thumbEl.className = "batch-thumb-badge";
        thumbEl.textContent = "PDF";
      }

      const meta = document.createElement("div");
      meta.className = "batch-meta";

      const name = document.createElement("span");
      name.className = "batch-name";
      name.textContent = item.file.name || "clipboard-image.png";

      const status = document.createElement("span");
      status.className = `batch-status ${item.status}`;
      status.textContent =
        item.status === "processing"
          ? "Processing…"
          : item.status === "done"
          ? "Ready"
          : item.status === "error"
          ? "Error"
          : "Queued";

      meta.append(name, status);
      card.append(thumbEl, meta);
      els.batchStrip.appendChild(card);
    });
  }

  function getPreviewSources(item) {
    if (!item) {
      return {
        canCompare: false,
        mainSrc: null,
        beforeSrc: null,
        afterSrc: null,
      };
    }

    if (state.mode === "pdf") {
      const d = item.pdfData;
      const beforeSrc =
        d && d.before_image_base64
          ? `data:image/jpeg;base64,${d.before_image_base64}`
          : item.isPdf
          ? null
          : item.url;
      const afterSrc =
        d && d.after_image_base64
          ? `data:image/png;base64,${d.after_image_base64}`
          : null;
      const canCompare = Boolean(beforeSrc && afterSrc);
      const mainSrc =
        state.compareView === "before" && beforeSrc
          ? beforeSrc
          : afterSrc || beforeSrc;
      return { canCompare, mainSrc, beforeSrc, afterSrc };
    }

    if (state.mode === "redact") {
      const d = item.redactData;
      const beforeSrc =
        d && d.before_image_base64
          ? `data:image/jpeg;base64,${d.before_image_base64}`
          : item.isPdf
          ? null
          : item.url;
      const afterSrc =
        d && d.after_image_base64
          ? `data:image/png;base64,${d.after_image_base64}`
          : null;
      const canCompare = Boolean(beforeSrc && afterSrc);
      const mainSrc =
        state.compareView === "before" && beforeSrc
          ? beforeSrc
          : afterSrc || beforeSrc;
      return { canCompare, mainSrc, beforeSrc, afterSrc };
    }

    return {
      canCompare: false,
      mainSrc: item.isPdf ? null : item.url,
      beforeSrc: null,
      afterSrc: null,
    };
  }

  function renderActiveItem() {
    const item = getActiveItem();
    if (!item) {
      els.imageEmptyState.classList.remove("hidden");
      els.pdfPendingState.classList.add("hidden");
      els.canvasWrapper.classList.add("hidden");
      els.compareSwitchGroup.classList.add("hidden");
      els.compareSliderBar.classList.add("hidden");
      els.beforeCompareImage.classList.add("hidden");
      els.compareDivider.classList.add("hidden");
      resetInspector();
      els.dimensionsChip.classList.add("hidden");
      els.outputEmptyState.textContent = "Results will appear here after processing.";
      els.outputEmptyState.classList.remove("hidden");
      els.docSummaryCard.classList.add("hidden");
      els.docSummaryCard.innerHTML = "";
      els.rawTextLines.classList.add("hidden");
      els.outputPre.classList.add("hidden");
      els.barcodeCards.classList.add("hidden");
      els.latencyChip.classList.add("hidden");
      els.summaryChip.classList.add("hidden");
      els.copyBtn.disabled = true;
      els.downloadBtn.disabled = true;
      els.downloadBtn.textContent = "Download";
      return;
    }

    const sources = getPreviewSources(item);
    els.compareSwitchGroup.classList.toggle("hidden", !sources.canCompare);

    const isSplit = sources.canCompare && state.compareView === "split";
    els.compareSliderBar.classList.toggle("hidden", !isSplit);
    els.beforeCompareImage.classList.toggle("hidden", !isSplit);
    els.compareDivider.classList.toggle("hidden", !isSplit);

    if (!sources.mainSrc) {
      els.imageEmptyState.classList.add("hidden");
      els.canvasWrapper.classList.add("hidden");
      els.pdfPendingState.classList.remove("hidden");
      els.pdfPendingTitle.textContent = item.file.name || "PDF Document";
      els.pdfPendingHint.textContent =
        !supportsPdfInput(state.mode)
          ? "Switch to Searchable PDF, PII Redact, or AI Extract mode to process PDF files."
          : item.error
          ? `Processing error: ${item.error}`
          : item.status === "done"
          ? "PDF processed via OpenAI /v1/chat/completions (raster preview omitted in OpenAI JSON)."
          : "Rasterising and running on-device OCR…";
      els.dimensionsChip.classList.add("hidden");
    } else {
      els.imageEmptyState.classList.add("hidden");
      els.pdfPendingState.classList.add("hidden");
      els.canvasWrapper.classList.remove("hidden");

      els.previewImage.onload = () => {
        renderOverlays(item);
        if (isSplit) syncSliderVisuals();
      };
      els.previewImage.src = sources.mainSrc;

      if (isSplit && sources.beforeSrc) {
        els.beforeCompareImage.onload = () => {
          syncOverlayBounds();
          syncSliderVisuals();
        };
        els.beforeCompareImage.src = sources.beforeSrc;
      } else {
        els.beforeCompareImage.removeAttribute("src");
      }

      if (els.previewImage.complete) {
        renderOverlays(item);
        if (isSplit) syncSliderVisuals();
      }
      if (typeof requestAnimationFrame === "function") {
        requestAnimationFrame(() => syncOverlayBounds());
      }
    }

    renderOutput(item);
  }

  function extractOverlayBoxes(item) {
    if (!item) return [];
    const boxes = [];

    if (state.mode === "barcode") {
      const data = item.barcodeData;
      if (!data) return [];
      (data.barcodes || []).forEach((b, idx) => {
        if (b.bounding_box) {
          boxes.push({
            id: `box-barcode-${idx}`,
            box: b.bounding_box,
            label: b.display_value || b.raw_value || "(empty)",
            isRedact: false,
          });
        }
      });
      return boxes;
    }

    if (state.mode === "redact") {
      const data = item.redactData;
      if (!data) return [];
      (data.regions || []).forEach((region, idx) => {
        if ((region.page_index || 0) === 0 && region.bounding_box) {
          boxes.push({
            id: `box-redact-${idx}`,
            box: region.bounding_box,
            label: `${String(region.category || "pii").toUpperCase()} · ${
              region.masked_preview || "[REDACTED]"
            }`,
            isRedact: true,
          });
        }
      });
      return boxes;
    }

    if (state.mode === "pdf" || state.mode === "ai") {
      return [];
    }

    const data = item.ocrData;
    if (!data) return [];
    const blocks = data.blocks || [];
    if (state.overlayLevel === "blocks") {
      blocks.forEach((blk, bIdx) => {
        if (blk.bounding_box) {
          boxes.push({
            id: `box-block-${bIdx}`,
            box: blk.bounding_box,
            label: blk.text || "",
            isRedact: false,
          });
        }
      });
    } else {
      blocks.forEach((blk, bIdx) => {
        (blk.lines || []).forEach((line, lIdx) => {
          if (line.bounding_box) {
            boxes.push({
              id: `box-line-${bIdx}-${lIdx}`,
              box: line.bounding_box,
              label: line.text || "",
              isRedact: false,
            });
          }
        });
      });
    }
    return boxes;
  }

  function syncOverlayBounds() {
    const img = els.previewImage;
    const svg = els.overlaySvg;
    const beforeImg = els.beforeCompareImage;
    if (!img || !svg) return;

    if (img.clientWidth > 0 && img.clientHeight > 0) {
      const left = `${img.offsetLeft}px`;
      const top = `${img.offsetTop}px`;
      const width = `${img.clientWidth}px`;
      const height = `${img.clientHeight}px`;

      svg.style.left = left;
      svg.style.top = top;
      svg.style.width = width;
      svg.style.height = height;

      if (beforeImg && !beforeImg.classList.contains("hidden")) {
        beforeImg.style.left = left;
        beforeImg.style.top = top;
        beforeImg.style.width = width;
        beforeImg.style.height = height;
      }

      if (state.compareView === "split") {
        updateSplitClip();
      }
    }
  }

  function renderOverlays(item) {
    const svg = els.overlaySvg;
    svg.innerHTML = "";
    syncOverlayBounds();

    const data =
      state.mode === "barcode"
        ? item.barcodeData
        : state.mode === "redact"
        ? item.redactData
        : state.mode === "pdf"
        ? item.pdfData
        : state.mode === "ai"
        ? item.aiData
        : item.ocrData;

    let width = (data && data.image_width) || els.previewImage.naturalWidth || 0;
    let height = (data && data.image_height) || els.previewImage.naturalHeight || 0;

    if (
      state.mode === "pdf" &&
      data &&
      Array.isArray(data.pages) &&
      data.pages.length > 0
    ) {
      width = data.pages[0].width || width;
      height = data.pages[0].height || height;
    }

    if (width > 0 && height > 0) {
      els.dimensionsChip.textContent = `${width}×${height}`;
      els.dimensionsChip.classList.remove("hidden");
      svg.setAttribute("viewBox", `0 0 ${width} ${height}`);
    } else {
      els.dimensionsChip.classList.add("hidden");
    }

    if (!state.showOverlays || !data || width <= 0 || height <= 0) {
      return;
    }

    const boxes = extractOverlayBoxes(item);
    const ns = "http://www.w3.org/2000/svg";

    boxes.forEach((entry) => {
      const rect = document.createElementNS(ns, "rect");
      rect.setAttribute("x", String(entry.box.left));
      rect.setAttribute("y", String(entry.box.top));
      rect.setAttribute("width", String(Math.max(1, entry.box.width)));
      rect.setAttribute("height", String(Math.max(1, entry.box.height)));
      rect.dataset.boxId = entry.id;
      rect.setAttribute(
        "class",
        `bbox-rect${entry.isRedact ? " redact-box" : ""}${
          state.selectedBoxId === entry.id ? " active" : ""
        }`
      );

      rect.addEventListener("mouseenter", () => {
        setHoveredBox(entry.id, entry.label);
      });
      rect.addEventListener("mouseleave", () => {
        setHoveredBox(null, "");
      });
      rect.addEventListener("click", (e) => {
        e.stopPropagation();
        if (state.selectedBoxId === entry.id) {
          clearBoxSelection();
        } else {
          selectBox(entry.id, entry.label, true);
        }
      });

      svg.appendChild(rect);
    });
  }

  function formatByteSize(bytes) {
    if (typeof bytes !== "number" || Number.isNaN(bytes)) return "—";
    if (bytes < 1024) return `${bytes} B`;
    if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
    return `${(bytes / (1024 * 1024)).toFixed(2)} MB`;
  }

  function getAiOutputContent(aiData) {
    if (!aiData || !Array.isArray(aiData.choices) || aiData.choices.length === 0) {
      return "";
    }
    const msg = aiData.choices[0].message;
    return (msg && typeof msg.content === "string") ? msg.content : "";
  }

  function getOutputText(item) {
    if (!item || item.error) return item ? `Error: ${item.error}` : "";
    if (state.mode === "barcode") {
      return item.barcodeData ? JSON.stringify(item.barcodeData, null, 2) : "";
    }
    if (state.mode === "pdf") {
      return item.pdfData ? item.pdfData.text || "" : "";
    }
    if (state.mode === "redact") {
      return item.redactData ? item.redactData.sanitized_text || "" : "";
    }
    if (state.mode === "ai") {
      return getAiOutputContent(item.aiData);
    }
    if (!item.ocrData) return "";
    if (state.mode === "raw") {
      return item.ocrData.text || "";
    }
    return JSON.stringify(item.ocrData, null, 2);
  }

  function renderOutput(item) {
    els.docSummaryCard.classList.add("hidden");
    els.docSummaryCard.innerHTML = "";
    els.barcodeCards.classList.add("hidden");
    els.barcodeCards.innerHTML = "";
    els.rawTextLines.classList.add("hidden");
    els.rawTextLines.innerHTML = "";
    els.outputPre.classList.add("hidden");
    els.outputEmptyState.classList.add("hidden");
    els.latencyChip.classList.add("hidden");
    els.summaryChip.classList.add("hidden");
    els.copyBtn.disabled = true;
    els.downloadBtn.disabled = true;
    els.downloadBtn.textContent = "Download";

    if (item.isPdf && !supportsPdfInput(state.mode)) {
      els.outputEmptyState.textContent =
        "PDF files are processed in Searchable PDF, PII Redact, or AI Extract mode.";
      els.outputEmptyState.classList.remove("hidden");
      return;
    }

    if (item.status === "processing" || item.status === "queued") {
      els.outputEmptyState.textContent = "Processing sequentially on device…";
      els.outputEmptyState.classList.remove("hidden");
      return;
    }

    if (item.error) {
      els.outputPre.textContent = `Error: ${item.error}`;
      els.outputPre.classList.remove("hidden");
      return;
    }

    if (state.mode === "pdf") {
      const data = item.pdfData;
      if (!data) return;

      els.latencyChip.textContent = `${data.processing_ms} ms`;
      els.latencyChip.classList.remove("hidden");
      els.summaryChip.textContent = `${data.page_count} page(s) · ${formatByteSize(
        data.byte_length
      )}`;
      els.summaryChip.classList.remove("hidden");

      const targetBadge = data.target_max_size_mb
        ? `<span class="status-badge ${
            data.target_size_met ? "success" : "danger"
          }">${
            data.target_size_met ? "Target Met" : "Min Size Reached"
          } (≤ ${escapeHtml(data.target_max_size_mb)} MB)</span>`
        : "";
      const enhanceBadge = data.contrast_enhanced
        ? `<span class="status-badge">Contrast Cleaned</span>`
        : "";
      const metaBadge = data.metadata_stripped
        ? `<span class="status-badge success">EXIF &amp; Metadata Stripped</span>`
        : "";

      els.docSummaryCard.innerHTML = `
        <div class="doc-summary-grid">
          <div class="doc-metric">
            <span class="doc-metric-label">Pages</span>
            <span class="doc-metric-value">${data.page_count}</span>
          </div>
          <div class="doc-metric">
            <span class="doc-metric-label">PDF Size</span>
            <span class="doc-metric-value">${formatByteSize(data.byte_length)}</span>
          </div>
          <div class="doc-metric">
            <span class="doc-metric-label">Page Format</span>
            <span class="doc-metric-value">${escapeHtml(
              String(data.page_format || "a4").toUpperCase()
            )}</span>
          </div>
          <div class="doc-metric">
            <span class="doc-metric-label">Quality / Scale</span>
            <span class="doc-metric-value">Q${data.applied_jpeg_quality} · ${Math.round(
        (data.applied_scale_factor || 1) * 100
      )}%</span>
          </div>
        </div>
        <div class="doc-badges-row">
          <span class="status-badge success">Invisible Text Layer Embedded</span>
          ${metaBadge}
          ${enhanceBadge}
          ${targetBadge}
        </div>
      `;
      els.docSummaryCard.classList.remove("hidden");

      els.outputPre.textContent =
        data.text && data.text.length > 0
          ? data.text
          : "(No selectable text detected)";
      els.outputPre.classList.remove("hidden");

      els.copyBtn.disabled = !data.text;
      els.downloadBtn.disabled = !data.pdf_base64;
      els.downloadBtn.textContent = "Download PDF";
      return;
    }

    if (state.mode === "redact") {
      const data = item.redactData;
      if (!data) return;

      els.latencyChip.textContent = `${data.processing_ms} ms`;
      els.latencyChip.classList.remove("hidden");
      els.summaryChip.textContent = `${data.redacted_count} masked`;
      els.summaryChip.classList.remove("hidden");

      const counts = data.category_counts || {};
      const keepLast4Badge = data.keep_last_4
        ? `<span class="status-badge">Last 4 Digits Preserved</span>`
        : "";
      const metaBadge = data.metadata_stripped
        ? `<span class="status-badge success">EXIF &amp; GPS Stripped</span>`
        : "";
      const enhanceBadge = data.contrast_enhanced
        ? `<span class="status-badge">Contrast Cleaned</span>`
        : "";

      els.docSummaryCard.innerHTML = `
        <div class="doc-summary-grid">
          <div class="doc-metric">
            <span class="doc-metric-label">Total Masked</span>
            <span class="doc-metric-value">${data.redacted_count}</span>
          </div>
          <div class="doc-metric">
            <span class="doc-metric-label">IDs / Cards</span>
            <span class="doc-metric-value">${counts.id || 0}</span>
          </div>
          <div class="doc-metric">
            <span class="doc-metric-label">Contacts</span>
            <span class="doc-metric-value">${counts.contact || 0}</span>
          </div>
          <div class="doc-metric">
            <span class="doc-metric-label">Addresses / Faces</span>
            <span class="doc-metric-value">${counts.address || 0} / ${
        counts.face || 0
      }</span>
          </div>
        </div>
        <div class="doc-badges-row">
          <span class="status-badge success">Pixels Permanently Burned</span>
          ${metaBadge}
          ${keepLast4Badge}
          ${enhanceBadge}
        </div>
      `;
      els.docSummaryCard.classList.remove("hidden");

      const regions = data.regions || [];
      if (regions.length > 0) {
        els.barcodeCards.classList.remove("hidden");
        regions.forEach((region, idx) => {
          const boxId = `box-redact-${idx}`;
          const card = document.createElement("div");
          card.className = `barcode-card${
            state.selectedBoxId === boxId ? " active" : ""
          }`;
          card.dataset.boxId = boxId;

          const top = document.createElement("div");
          top.className = "barcode-card-top";
          top.innerHTML = `<span>#${idx + 1} · ${escapeHtml(
            String(region.category || "pii").toUpperCase()
          )}</span><span>Page ${(region.page_index || 0) + 1}</span>`;

          const val = document.createElement("div");
          val.className = "barcode-value";
          val.textContent = region.masked_preview || "[REDACTED]";

          card.addEventListener("mouseenter", () => {
            const rect = els.overlaySvg.querySelector(
              `.bbox-rect[data-box-id="${CSS.escape(boxId)}"]`
            );
            if (rect) rect.classList.add("active");
          });
          card.addEventListener("mouseleave", () => {
            const rect = els.overlaySvg.querySelector(
              `.bbox-rect[data-box-id="${CSS.escape(boxId)}"]`
            );
            if (rect && state.selectedBoxId !== boxId) {
              rect.classList.remove("active");
            }
          });
          card.addEventListener("click", () => {
            if (state.selectedBoxId === boxId) {
              clearBoxSelection();
            } else {
              selectBox(
                boxId,
                `${String(region.category || "pii").toUpperCase()} · ${
                  region.masked_preview || "[REDACTED]"
                }`,
                false
              );
            }
          });

          card.append(top, val);
          els.barcodeCards.appendChild(card);
        });
      }

      els.outputPre.textContent =
        data.sanitized_text && data.sanitized_text.length > 0
          ? data.sanitized_text
          : "(No readable text remaining)";
      els.outputPre.classList.remove("hidden");

      els.copyBtn.disabled = !data.sanitized_text;
      els.downloadBtn.disabled =
        state.redactOptions.outputFormat === "pdf"
          ? !data.pdf_base64
          : !data.after_image_base64;
      els.downloadBtn.textContent =
        state.redactOptions.outputFormat === "pdf"
          ? "Download PDF"
          : "Download PNG";
      return;
    }

    if (state.mode === "barcode") {
      const data = item.barcodeData;
      if (!data) return;
      els.latencyChip.textContent = `${data.inference_ms} ms`;
      els.latencyChip.classList.remove("hidden");
      els.summaryChip.textContent = `${data.count || 0} code(s)`;
      els.summaryChip.classList.remove("hidden");

      const barcodes = data.barcodes || [];
      if (barcodes.length > 0) {
        els.barcodeCards.classList.remove("hidden");
        barcodes.forEach((b, i) => {
          const boxId = `box-barcode-${i}`;
          const textVal = b.display_value || b.raw_value || "(empty)";
          const card = document.createElement("div");
          card.className = `barcode-card${
            state.selectedBoxId === boxId ? " active" : ""
          }`;
          card.dataset.boxId = boxId;

          const top = document.createElement("div");
          top.className = "barcode-card-top";
          top.innerHTML = `<span>#${i + 1} · ${escapeHtml(
            b.format || "unknown"
          )}</span><span>${escapeHtml(b.value_type || "")}</span>`;

          const val = document.createElement("div");
          val.className = "barcode-value";
          val.textContent = textVal;

          card.addEventListener("click", () => {
            if (state.selectedBoxId === boxId) {
              clearBoxSelection();
            } else {
              selectBox(boxId, textVal, false);
            }
          });

          card.append(top, val);
          els.barcodeCards.appendChild(card);
        });
      }

      els.outputPre.textContent = JSON.stringify(data, null, 2);
      els.outputPre.classList.remove("hidden");
      els.copyBtn.disabled = false;
      els.downloadBtn.disabled = false;
      return;
    }

    if (state.mode === "ai") {
      const data = item.aiData;
      if (!data) return;

      const content = getAiOutputContent(data);
      const meta = data.x_edge_metadata || {};
      const usage = data.usage || {};
      const intent = String(meta.intent || "ocr").toUpperCase();
      const tier = String(meta.tier_used || "tier1_deterministic");
      const ms = typeof meta.processing_ms === "number" ? meta.processing_ms : 0;

      els.latencyChip.textContent = `${ms} ms`;
      els.latencyChip.classList.remove("hidden");
      els.summaryChip.textContent = `${intent} · ${usage.completion_tokens || 0} tok`;
      els.summaryChip.classList.remove("hidden");

      const fallbackBadge = meta.fallback_triggered
        ? `<span class="status-badge">Tier 1 Fallback</span>`
        : "";
      const jsonBadge =
        state.aiOptions.jsonMode || meta.intent === "receipt"
          ? `<span class="status-badge success">Valid JSON</span>`
          : "";

      els.docSummaryCard.innerHTML = `
        <div class="doc-summary-grid">
          <div class="doc-metric">
            <span class="doc-metric-label">Intent</span>
            <span class="doc-metric-value">${escapeHtml(intent)}</span>
          </div>
          <div class="doc-metric">
            <span class="doc-metric-label">Tier</span>
            <span class="doc-metric-value">${escapeHtml(tier)}</span>
          </div>
          <div class="doc-metric">
            <span class="doc-metric-label">Prompt / Completion</span>
            <span class="doc-metric-value">${usage.prompt_tokens || 0} / ${
        usage.completion_tokens || 0
      }</span>
          </div>
          <div class="doc-metric">
            <span class="doc-metric-label">Model</span>
            <span class="doc-metric-value">${escapeHtml(data.model || "local-edge-vision")}</span>
          </div>
        </div>
        <div class="doc-badges-row">
          <span class="status-badge success">OpenAI /v1/chat/completions</span>
          ${jsonBadge}
          ${fallbackBadge}
        </div>
      `;
      els.docSummaryCard.classList.remove("hidden");

      els.outputPre.textContent =
        content.length > 0 ? content : "(No content returned)";
      els.outputPre.classList.remove("hidden");
      els.copyBtn.disabled = content.length === 0;
      els.downloadBtn.disabled = content.length === 0;
      els.downloadBtn.textContent =
        meta.intent === "vcard" && !state.aiOptions.jsonMode
          ? "Download .vcf"
          : meta.intent === "table" && !state.aiOptions.jsonMode
          ? "Download .md"
          : state.aiOptions.jsonMode || meta.intent === "receipt"
          ? "Download .json"
          : "Download .txt";
      return;
    }

    const data = item.ocrData;
    if (!data) return;

    els.latencyChip.textContent = `${data.inference_ms} ms`;
    els.latencyChip.classList.remove("hidden");

    const langs = data.detected_languages || [];
    if (langs.length > 0) {
      els.summaryChip.textContent =
        langs.length > 2
          ? `${langs[0]}, ${langs[1]} (+${langs.length - 2})`
          : langs.join(", ");
      els.summaryChip.title = langs.join(", ");
      els.summaryChip.classList.remove("hidden");
    }

    if (state.mode === "raw") {
      const segments = [];
      const blocks = data.blocks || [];
      if (state.overlayLevel === "blocks") {
        blocks.forEach((blk, bIdx) => {
          if (blk.text) {
            segments.push({ id: `box-block-${bIdx}`, text: blk.text });
          }
        });
      } else {
        blocks.forEach((blk, bIdx) => {
          (blk.lines || []).forEach((line, lIdx) => {
            if (line.text) {
              segments.push({
                id: `box-line-${bIdx}-${lIdx}`,
                text: line.text,
              });
            }
          });
        });
      }

      if (segments.length > 0) {
        els.rawTextLines.classList.remove("hidden");
        segments.forEach((seg) => {
          const div = document.createElement("div");
          div.className = `text-segment${
            state.selectedBoxId === seg.id ? " active" : ""
          }`;
          div.dataset.boxId = seg.id;
          div.textContent = seg.text;

          div.addEventListener("mouseenter", () => {
            const rect = els.overlaySvg.querySelector(
              `.bbox-rect[data-box-id="${CSS.escape(seg.id)}"]`
            );
            if (rect) rect.classList.add("active");
          });
          div.addEventListener("mouseleave", () => {
            const rect = els.overlaySvg.querySelector(
              `.bbox-rect[data-box-id="${CSS.escape(seg.id)}"]`
            );
            if (rect && state.selectedBoxId !== seg.id) {
              rect.classList.remove("active");
            }
          });
          div.addEventListener("click", () => {
            const sel = window.getSelection();
            if (sel && sel.toString().length > 0) return;
            if (state.selectedBoxId === seg.id) {
              clearBoxSelection();
            } else {
              selectBox(seg.id, seg.text, false);
            }
          });

          els.rawTextLines.appendChild(div);
        });
      } else {
        els.outputPre.textContent =
          data.text && data.text.length > 0
            ? data.text
            : "(No text detected)";
        els.outputPre.classList.remove("hidden");
      }
    } else {
      els.outputPre.textContent = JSON.stringify(data, null, 2);
      els.outputPre.classList.remove("hidden");
    }

    els.copyBtn.disabled = false;
    els.downloadBtn.disabled = false;
  }

  function escapeHtml(str) {
    return String(str)
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;");
  }

  function base64ToBlob(base64Str, mimeType) {
    const binary = atob(base64Str);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) {
      bytes[i] = binary.charCodeAt(i);
    }
    return new Blob([bytes], { type: mimeType });
  }

  function triggerBlobDownload(blob, filename) {
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  }

  async function copyText(text, btn) {
    if (!text) return;
    try {
      await navigator.clipboard.writeText(text);
    } catch (_) {
      const ta = document.createElement("textarea");
      ta.value = text;
      ta.style.position = "fixed";
      ta.style.opacity = "0";
      document.body.appendChild(ta);
      ta.select();
      document.execCommand("copy");
      document.body.removeChild(ta);
    }
    const prev = btn.textContent;
    btn.textContent = "Copied!";
    setTimeout(() => {
      btn.textContent = prev;
    }, 1400);
  }

  async function downloadBatchZip() {
    if (state.batch.length === 0 || state.isQueueRunning) return;

    const btn = els.downloadBatchZipBtn;
    const prevLabel = btn.textContent;
    btn.disabled = true;
    btn.textContent = "Packaging .zip…";

    try {
      const formData = new FormData();
      state.batch.forEach((item, index) => {
        const fallback = item.isPdf ? `doc_${index + 1}.pdf` : `img_${index + 1}.png`;
        formData.append("files", item.file, item.file.name || fallback);
      });

      const isRedact = state.mode === "redact";
      const qs = new URLSearchParams({
        mode: isRedact ? "redact" : "searchable-pdf",
        script: state.script,
      });

      if (isRedact) {
        qs.set(
          "presets",
          state.redactOptions.presets.length > 0
            ? state.redactOptions.presets.join(",")
            : "all"
        );
        qs.set("keep_last_4", String(state.redactOptions.keepLast4));
        qs.set("enhance", String(state.redactOptions.enhance));
        qs.set("output_format", state.redactOptions.outputFormat);
      } else {
        qs.set("page_format", state.pdfOptions.pageFormat);
        qs.set("enhance", String(state.pdfOptions.enhance));
        if (state.pdfOptions.maxSizeMb) {
          qs.set("max_size_mb", state.pdfOptions.maxSizeMb);
        }
      }

      const response = await fetch(`/v1/doc/batch-zip?${qs.toString()}`, {
        method: "POST",
        body: formData,
      });
      if (!response.ok) {
        const errPayload = await response.json().catch(() => ({}));
        throw new Error(
          errPayload.message || errPayload.error || `HTTP ${response.status}`
        );
      }

      const zipBlob = await response.blob();
      triggerBlobDownload(zipBlob, "droid_edge_batch.zip");
    } catch (err) {
      els.outputPre.textContent = `Batch ZIP Error: ${
        err instanceof Error ? err.message : String(err)
      }`;
      els.outputPre.classList.remove("hidden");
    } finally {
      btn.textContent = prevLabel;
      updateBatchZipButton();
    }
  }

  // Event wiring
  els.modeBtns.forEach((btn, idx) => {
    btn.addEventListener("click", () => setMode(btn.dataset.mode));
    btn.addEventListener("keydown", (e) => {
      if (e.key === "ArrowRight" || e.key === "ArrowLeft") {
        e.preventDefault();
        const delta = e.key === "ArrowRight" ? 1 : -1;
        const nextIdx = (idx + delta + els.modeBtns.length) % els.modeBtns.length;
        const target = els.modeBtns[nextIdx];
        target.focus();
        setMode(target.dataset.mode);
      }
    });
  });

  els.scriptSelect.addEventListener("change", (e) => {
    state.script = e.target.value;
    clearBoxSelection();
    state.batch.forEach((item) => {
      item.ocrData = null;
      item.pdfData = null;
      item.redactData = null;
      item.aiData = null;
    });
    if (state.mode !== "barcode" && state.batch.length > 0) {
      enqueueAllBatchItems(true);
    }
  });

  function onPdfOptionsChanged() {
    state.pdfOptions.pageFormat = els.pdfPageFormatSelect.value;
    state.pdfOptions.maxSizeMb = els.pdfMaxSizeSelect.value;
    state.pdfOptions.enhance = els.pdfEnhanceToggle.checked;
    state.batch.forEach((item) => {
      item.pdfData = null;
    });
    if (state.mode === "pdf" && state.batch.length > 0) {
      enqueueAllBatchItems(true);
    }
  }

  els.pdfPageFormatSelect.addEventListener("change", onPdfOptionsChanged);
  els.pdfMaxSizeSelect.addEventListener("change", onPdfOptionsChanged);
  els.pdfEnhanceToggle.addEventListener("change", onPdfOptionsChanged);

  function onRedactOptionsChanged() {
    state.redactOptions.presets = els.presetCheckboxes
      .filter((cb) => cb.checked)
      .map((cb) => cb.dataset.preset);
    state.redactOptions.keepLast4 = els.keepLast4Toggle.checked;
    state.redactOptions.enhance = els.redactEnhanceToggle.checked;
    state.batch.forEach((item) => {
      item.redactData = null;
    });
    if (state.mode === "redact" && state.batch.length > 0) {
      enqueueAllBatchItems(true);
    }
  }

  els.presetCheckboxes.forEach((cb) => {
    cb.addEventListener("change", onRedactOptionsChanged);
  });
  els.keepLast4Toggle.addEventListener("change", onRedactOptionsChanged);
  els.redactEnhanceToggle.addEventListener("change", onRedactOptionsChanged);
  els.redactDownloadFormat.addEventListener("change", (e) => {
    state.redactOptions.outputFormat = e.target.value;
    const active = getActiveItem();
    if (active && state.mode === "redact") {
      renderOutput(active);
    }
  });

  function onAiOptionsChanged() {
    state.aiOptions.task = els.aiTaskSelect.value;
    state.aiOptions.customPrompt = els.aiPromptInput.value;
    state.aiOptions.jsonMode = els.aiJsonModeToggle.checked;
    updateToolbarVisibility();
    state.batch.forEach((item) => {
      item.aiData = null;
    });
    if (state.mode === "ai" && state.batch.length > 0) {
      enqueueAllBatchItems(true);
    }
  }

  els.aiTaskSelect.addEventListener("change", onAiOptionsChanged);
  els.aiJsonModeToggle.addEventListener("change", onAiOptionsChanged);
  els.aiPromptInput.addEventListener("input", (e) => {
    state.aiOptions.customPrompt = e.target.value;
  });
  els.aiPromptInput.addEventListener("keydown", (e) => {
    if (e.key === "Enter") {
      e.preventDefault();
      onAiOptionsChanged();
    }
  });
  els.aiRunBtn.addEventListener("click", onAiOptionsChanged);

  els.compareBtns.forEach((btn) => {
    btn.addEventListener("click", () => setCompareView(btn.dataset.compare));
  });

  els.compareSlider.addEventListener("input", syncSliderVisuals);

  els.overlayToggle.addEventListener("change", (e) => {
    state.showOverlays = e.target.checked;
    const active = getActiveItem();
    if (active) renderOverlays(active);
  });

  els.overlayLevelSelect.addEventListener("change", (e) => {
    state.overlayLevel = e.target.value;
    clearBoxSelection();
    const active = getActiveItem();
    if (active) {
      renderOverlays(active);
      renderOutput(active);
    }
  });

  els.clearBoxBtn.addEventListener("click", clearBoxSelection);
  els.copyBoxBtn.addEventListener("click", () => {
    copyText(state.selectedBoxText, els.copyBoxBtn);
  });

  els.overlaySvg.addEventListener("click", () => {
    clearBoxSelection();
  });

  window.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && state.selectedBoxId) {
      clearBoxSelection();
    }
  });

  els.dropZone.addEventListener("click", () => els.fileInput.click());
  els.dropZone.addEventListener("keydown", (e) => {
    if (e.key === "Enter" || e.key === " ") {
      e.preventDefault();
      els.fileInput.click();
    }
  });

  els.fileInput.addEventListener("change", (e) => {
    addFiles(e.target.files);
    els.fileInput.value = "";
  });

  ["dragenter", "dragover"].forEach((evt) => {
    els.dropZone.addEventListener(evt, (e) => {
      e.preventDefault();
      els.dropZone.classList.add("drag-over");
    });
  });

  ["dragleave", "drop"].forEach((evt) => {
    els.dropZone.addEventListener(evt, (e) => {
      e.preventDefault();
      els.dropZone.classList.remove("drag-over");
    });
  });

  els.dropZone.addEventListener("drop", (e) => {
    if (e.dataTransfer && e.dataTransfer.files) {
      addFiles(e.dataTransfer.files);
    }
  });

  window.addEventListener("paste", (e) => {
    const items = e.clipboardData && e.clipboardData.items;
    if (!items) return;
    const files = [];
    for (const item of items) {
      if (
        item.kind === "file" &&
        (item.type.startsWith("image/") || item.type === "application/pdf")
      ) {
        const f = item.getAsFile();
        if (f) files.push(f);
      }
    }
    if (files.length > 0) {
      addFiles(files);
    }
  });

  window.addEventListener("dragover", (e) => {
    e.preventDefault();
    els.dropZone.classList.add("drag-over");
  });

  window.addEventListener("dragleave", (e) => {
    if (e.relatedTarget === null) {
      els.dropZone.classList.remove("drag-over");
    }
  });

  window.addEventListener("drop", (e) => {
    e.preventDefault();
    els.dropZone.classList.remove("drag-over");
    if (e.target !== els.dropZone && !els.dropZone.contains(e.target)) {
      if (e.dataTransfer && e.dataTransfer.files) {
        addFiles(e.dataTransfer.files);
      }
    }
  });

  els.clearBatchBtn.addEventListener("click", () => {
    state.batch.forEach((item) => {
      if (item.url) URL.revokeObjectURL(item.url);
    });
    state.batch = [];
    state.queue = [];
    state.activeId = null;
    clearBoxSelection();
    els.clearBatchBtn.disabled = true;
    els.dropZone.classList.remove("compact");
    updateBatchZipButton();
    renderBatchStrip();
    renderActiveItem();
  });

  els.downloadBatchZipBtn.addEventListener("click", downloadBatchZip);

  els.copyBtn.addEventListener("click", () => {
    const text = getOutputText(getActiveItem());
    copyText(text, els.copyBtn);
  });

  els.downloadBtn.addEventListener("click", () => {
    const item = getActiveItem();
    if (!item) return;
    const baseName = (item.file.name || "document").replace(/\.[^.]+$/, "");

    if (state.mode === "pdf" && item.pdfData && item.pdfData.pdf_base64) {
      const blob = base64ToBlob(item.pdfData.pdf_base64, "application/pdf");
      triggerBlobDownload(blob, `${baseName}_searchable.pdf`);
      return;
    }

    if (state.mode === "redact" && item.redactData) {
      if (
        state.redactOptions.outputFormat === "pdf" &&
        item.redactData.pdf_base64
      ) {
        const blob = base64ToBlob(item.redactData.pdf_base64, "application/pdf");
        triggerBlobDownload(blob, `${baseName}_redacted.pdf`);
        return;
      }
      if (item.redactData.after_image_base64) {
        const blob = base64ToBlob(
          item.redactData.after_image_base64,
          "image/png"
        );
        triggerBlobDownload(blob, `${baseName}_redacted.png`);
        return;
      }
    }

    const text = getOutputText(item);
    if (!text) return;

    if (state.mode === "ai" && item.aiData) {
      const intent = (item.aiData.x_edge_metadata && item.aiData.x_edge_metadata.intent) || "ocr";
      let aiExt = "txt";
      let aiMime = "text/plain";
      if (state.aiOptions.jsonMode || intent === "receipt") {
        aiExt = "json";
        aiMime = "application/json";
      } else if (intent === "table") {
        aiExt = "md";
        aiMime = "text/markdown";
      } else if (intent === "vcard") {
        aiExt = "vcf";
        aiMime = "text/vcard";
      }
      const aiBlob = new Blob([text], { type: `${aiMime};charset=utf-8` });
      triggerBlobDownload(aiBlob, `${baseName}.${aiExt}`);
      return;
    }

    const ext = state.mode === "raw" ? "txt" : "json";
    const mimeType = state.mode === "raw" ? "text/plain" : "application/json";
    const blob = new Blob([text], { type: `${mimeType};charset=utf-8` });
    triggerBlobDownload(blob, `${baseName}.${ext}`);
  });

  if (typeof ResizeObserver !== "undefined" && els.canvasWrapper) {
    const ro = new ResizeObserver(() => syncOverlayBounds());
    ro.observe(els.canvasWrapper);
  }
  window.addEventListener("resize", syncOverlayBounds);

  updateToolbarVisibility();
  pollServerStatus();
  setInterval(pollServerStatus, 10000);
})();
