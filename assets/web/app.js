(() => {
  "use strict";

  const state = {
    mode: "raw", // "raw" | "json" | "barcode"
    script: "latin",
    showOverlays: true,
    overlayLevel: "lines", // "blocks" | "lines"
    batch: [], // Array<{ id, file, url, status, ocrData, barcodeData, error }>
    activeId: null,
    selectedBoxId: null,
    selectedBoxText: "",
  };

  const els = {
    serverStatusDot: document.getElementById("serverStatusDot"),
    serverStatusText: document.getElementById("serverStatusText"),
    modeBtns: Array.from(document.querySelectorAll(".mode-btn")),
    scriptPickerWrap: document.getElementById("scriptPickerWrap"),
    scriptSelect: document.getElementById("scriptSelect"),
    clearBatchBtn: document.getElementById("clearBatchBtn"),
    dropZone: document.getElementById("dropZone"),
    fileInput: document.getElementById("fileInput"),
    batchStrip: document.getElementById("batchStrip"),
    overlayToggle: document.getElementById("overlayToggle"),
    overlayLevelSelect: document.getElementById("overlayLevelSelect"),
    dimensionsChip: document.getElementById("dimensionsChip"),
    imageEmptyState: document.getElementById("imageEmptyState"),
    canvasWrapper: document.getElementById("canvasWrapper"),
    previewImage: document.getElementById("previewImage"),
    overlaySvg: document.getElementById("overlaySvg"),
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
    rawTextLines: document.getElementById("rawTextLines"),
    barcodeCards: document.getElementById("barcodeCards"),
    outputPre: document.getElementById("outputPre"),
  };

  function getActiveItem() {
    return state.batch.find((item) => item.id === state.activeId) || null;
  }

  async function pollServerStatus() {
    try {
      const res = await fetch("/v1/status", { cache: "no-store" });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      els.serverStatusDot.className = "dot online";
      const battery = data.telemetry && typeof data.telemetry.battery_level === "number"
        ? ` · ${data.telemetry.battery_level}%`
        : "";
      const host = data.hostname || window.location.host;
      els.serverStatusText.textContent = `${host}${battery}`;
    } catch (_) {
      els.serverStatusDot.className = "dot offline";
      els.serverStatusText.textContent = "Server unreachable";
    }
  }

  const DEFAULT_INSPECTOR_HINT = "Hover or click a bounding box to inspect or copy";

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
    document.querySelectorAll(".text-segment.active, .barcode-card.active").forEach((el) => {
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
      const seg = document.querySelector(`.text-segment[data-box-id="${CSS.escape(boxId)}"]`);
      if (seg) seg.classList.add("hovered");
      if (!state.selectedBoxId) {
        showInspector("Hover", text, false);
      }
    } else if (!state.selectedBoxId) {
      resetInspector();
    }
  }

  function setMode(nextMode) {
    state.mode = nextMode;
    clearBoxSelection();
    els.modeBtns.forEach((btn) => {
      const active = btn.dataset.mode === nextMode;
      btn.classList.toggle("active", active);
      btn.setAttribute("aria-selected", String(active));
    });

    const isBarcode = nextMode === "barcode";
    els.scriptPickerWrap.classList.toggle("hidden", isBarcode);
    els.overlayLevelSelect.classList.toggle("hidden", isBarcode);

    if (nextMode === "raw") {
      els.outputHeading.textContent = "Extracted Text";
    } else if (nextMode === "json") {
      els.outputHeading.textContent = "Structured JSON";
    } else {
      els.outputHeading.textContent = "Barcode Scan";
    }

    const activeItem = getActiveItem();
    if (activeItem) {
      const needsBarcode = isBarcode && !activeItem.barcodeData && !activeItem.error;
      const needsOcr = !isBarcode && !activeItem.ocrData && !activeItem.error;
      if (needsBarcode || needsOcr) {
        processItem(activeItem);
      } else {
        renderActiveItem();
      }
    }
  }

  function addFiles(fileList) {
    const imageFiles = Array.from(fileList || []).filter((f) =>
      f.type.startsWith("image/") || /\.(png|jpe?g|webp|bmp|gif)$/i.test(f.name)
    );
    if (imageFiles.length === 0) return;

    const newItems = imageFiles.map((file, idx) => ({
      id: `${Date.now()}-${Math.random().toString(36).slice(2, 8)}-${idx}`,
      file,
      url: URL.createObjectURL(file),
      status: "queued",
      ocrData: null,
      barcodeData: null,
      error: null,
    }));

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
      processItem(item);
    });
  }

  async function processItem(item) {
    item.status = "processing";
    item.error = null;
    renderBatchStrip();
    if (item.id === state.activeId) renderActiveItem();

    const isBarcode = state.mode === "barcode";
    const endpoint = isBarcode
      ? "/v1/barcode"
      : `/v1/ocr?script=${encodeURIComponent(state.script)}`;

    const formData = new FormData();
    formData.append("image", item.file, item.file.name || "image.png");

    try {
      const response = await fetch(endpoint, {
        method: "POST",
        body: formData,
      });
      const payload = await response.json();
      if (!response.ok) {
        throw new Error(payload.message || payload.error || `HTTP ${response.status}`);
      }
      if (isBarcode) {
        item.barcodeData = payload;
      } else {
        item.ocrData = payload;
      }
      item.status = "done";
    } catch (err) {
      item.status = "error";
      item.error = err instanceof Error ? err.message : String(err);
    }

    renderBatchStrip();
    if (item.id === state.activeId) {
      renderActiveItem();
    }
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
          const isBarcode = state.mode === "barcode";
          if ((isBarcode && !active.barcodeData) || (!isBarcode && !active.ocrData)) {
            processItem(active);
          } else {
            renderActiveItem();
          }
        }
      });

      const img = document.createElement("img");
      img.className = "batch-thumb";
      img.src = item.url;
      img.alt = item.file.name || "Batch image";

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
      card.append(img, meta);
      els.batchStrip.appendChild(card);
    });
  }

  function renderActiveItem() {
    const item = getActiveItem();
    if (!item) {
      els.imageEmptyState.classList.remove("hidden");
      els.canvasWrapper.classList.add("hidden");
      resetInspector();
      els.dimensionsChip.classList.add("hidden");
      els.outputEmptyState.classList.remove("hidden");
      els.rawTextLines.classList.add("hidden");
      els.outputPre.classList.add("hidden");
      els.barcodeCards.classList.add("hidden");
      els.latencyChip.classList.add("hidden");
      els.summaryChip.classList.add("hidden");
      els.copyBtn.disabled = true;
      els.downloadBtn.disabled = true;
      return;
    }

    els.imageEmptyState.classList.add("hidden");
    els.canvasWrapper.classList.remove("hidden");
    els.previewImage.src = item.url;
    els.previewImage.onload = () => renderOverlays(item);
    if (els.previewImage.complete) {
      renderOverlays(item);
    }

    renderOutput(item);
  }

  function extractOverlayBoxes(item) {
    const data = state.mode === "barcode" ? item.barcodeData : item.ocrData;
    if (!data) return [];

    const boxes = [];
    if (state.mode === "barcode") {
      (data.barcodes || []).forEach((b, idx) => {
        if (b.bounding_box) {
          boxes.push({
            id: `box-barcode-${idx}`,
            box: b.bounding_box,
            label: b.display_value || b.raw_value || "(empty)",
          });
        }
      });
    } else {
      const blocks = data.blocks || [];
      if (state.overlayLevel === "blocks") {
        blocks.forEach((blk, bIdx) => {
          if (blk.bounding_box) {
            boxes.push({
              id: `box-block-${bIdx}`,
              box: blk.bounding_box,
              label: blk.text || "",
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
              });
            }
          });
        });
      }
    }
    return boxes;
  }

  function syncOverlayBounds() {
    const img = els.previewImage;
    const svg = els.overlaySvg;
    if (!img || !svg) return;
    if (img.clientWidth > 0 && img.clientHeight > 0) {
      svg.style.left = `${img.offsetLeft}px`;
      svg.style.top = `${img.offsetTop}px`;
      svg.style.width = `${img.clientWidth}px`;
      svg.style.height = `${img.clientHeight}px`;
    }
  }

  function renderOverlays(item) {
    const svg = els.overlaySvg;
    svg.innerHTML = "";
    syncOverlayBounds();

    const data = state.mode === "barcode" ? item.barcodeData : item.ocrData;
    const width = (data && data.image_width) || els.previewImage.naturalWidth || 0;
    const height = (data && data.image_height) || els.previewImage.naturalHeight || 0;

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
        `bbox-rect${state.selectedBoxId === entry.id ? " active" : ""}`
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

  function getOutputText(item) {
    if (!item || item.error) return item ? `Error: ${item.error}` : "";
    if (state.mode === "barcode") {
      return item.barcodeData ? JSON.stringify(item.barcodeData, null, 2) : "";
    }
    if (!item.ocrData) return "";
    if (state.mode === "raw") {
      return item.ocrData.text || "";
    }
    return JSON.stringify(item.ocrData, null, 2);
  }

  function renderOutput(item) {
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

    if (item.status === "processing" || item.status === "queued") {
      els.outputEmptyState.textContent = "Processing on device…";
      els.outputEmptyState.classList.remove("hidden");
      return;
    }

    if (item.error) {
      els.outputPre.textContent = `Error: ${item.error}`;
      els.outputPre.classList.remove("hidden");
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
          card.className = `barcode-card${state.selectedBoxId === boxId ? " active" : ""}`;
          card.dataset.boxId = boxId;

          const top = document.createElement("div");
          top.className = "barcode-card-top";
          top.innerHTML = `<span>#${i + 1} · ${escapeHtml(b.format || "unknown")}</span><span>${escapeHtml(b.value_type || "")}</span>`;

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

    const data = item.ocrData;
    if (!data) return;

    els.latencyChip.textContent = `${data.inference_ms} ms`;
    els.latencyChip.classList.remove("hidden");

    const langs = data.detected_languages || [];
    if (langs.length > 0) {
      els.summaryChip.textContent = langs.length > 2
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
              segments.push({ id: `box-line-${bIdx}-${lIdx}`, text: line.text });
            }
          });
        });
      }

      if (segments.length > 0) {
        els.rawTextLines.classList.remove("hidden");
        segments.forEach((seg) => {
          const div = document.createElement("div");
          div.className = `text-segment${state.selectedBoxId === seg.id ? " active" : ""}`;
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
            // Do not override if user is drag-selecting text across lines.
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
        els.outputPre.textContent = data.text && data.text.length > 0
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

  async function copyText(text, btn) {
    if (!text) return;
    try {
      await navigator.clipboard.writeText(text);
      const prev = btn.textContent;
      btn.textContent = "Copied!";
      setTimeout(() => {
        btn.textContent = prev;
      }, 1400);
    } catch (_) {
      // Fallback for non-HTTPS LAN origins where navigator.clipboard may be restricted.
      const ta = document.createElement("textarea");
      ta.value = text;
      ta.style.position = "fixed";
      ta.style.opacity = "0";
      document.body.appendChild(ta);
      ta.select();
      document.execCommand("copy");
      document.body.removeChild(ta);
      const prev = btn.textContent;
      btn.textContent = "Copied!";
      setTimeout(() => {
        btn.textContent = prev;
      }, 1400);
    }
  }

  // Event wiring
  els.modeBtns.forEach((btn) => {
    btn.addEventListener("click", () => setMode(btn.dataset.mode));
  });

  els.scriptSelect.addEventListener("change", (e) => {
    state.script = e.target.value;
    clearBoxSelection();
    const active = getActiveItem();
    if (active && state.mode !== "barcode") {
      active.ocrData = null;
      processItem(active);
    }
  });

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
      if (item.kind === "file" && item.type.startsWith("image/")) {
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
    state.batch.forEach((item) => URL.revokeObjectURL(item.url));
    state.batch = [];
    state.activeId = null;
    clearBoxSelection();
    els.clearBatchBtn.disabled = true;
    els.dropZone.classList.remove("compact");
    renderBatchStrip();
    renderActiveItem();
  });

  els.copyBtn.addEventListener("click", () => {
    const text = getOutputText(getActiveItem());
    copyText(text, els.copyBtn);
  });

  els.downloadBtn.addEventListener("click", () => {
    const item = getActiveItem();
    const text = getOutputText(item);
    if (!item || !text) return;

    const ext = state.mode === "raw" ? "txt" : "json";
    const mimeType = state.mode === "raw" ? "text/plain" : "application/json";
    const baseName = (item.file.name || "result").replace(/\.[^.]+$/, "");
    const blob = new Blob([text], { type: `${mimeType};charset=utf-8` });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = `${baseName}.${ext}`;
    a.click();
    URL.revokeObjectURL(url);
  });

  if (typeof ResizeObserver !== "undefined" && els.canvasWrapper) {
    const ro = new ResizeObserver(() => syncOverlayBounds());
    ro.observe(els.canvasWrapper);
  }
  window.addEventListener("resize", syncOverlayBounds);

  pollServerStatus();
  setInterval(pollServerStatus, 10000);
})();
