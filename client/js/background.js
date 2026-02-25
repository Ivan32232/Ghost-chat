/**
 * Ghost Chat — Midjourney-style swirl ASCII background with WebGL post-processing.
 * Two-pass: 2D Canvas (ASCII swirl) → WebGL2 texture → scanlines + vignette.
 */
const GhostBG = (() => {

  // ── ASCII art logo ──
  const LOGO = [
    "  ____ _               _      ____ _           _   ",
    " / ___| |__   ___  ___| |_   / ___| |__   __ _| |_ ",
    "| |  _| '_ \\ / _ \\/ __| __| | |   | '_ \\ / _` | __|",
    "| |_| | | | | (_) \\__ \\ |_  | |___| | | | (_| | |_ ",
    " \\____|_| |_|\\___/|___/\\__|  \\____|_| |_|\\__,_|\\__|"
  ];

  // ── Crypto-themed text lines ──
  const LINES = [
    "/encrypt AES-256-GCM end-to-end encryption with unique IV per message, counter-based replay protection, 256-byte padded blocks",
    "/secure ECDH P-256 key exchange, HKDF derivation, perfect forward secrecy with automatic key rotation every 50 messages",
    "/protect zero-knowledge architecture, no logs, no analytics, no metadata, stateless signaling relay, ephemeral room tokens",
    "/ghost peer-to-peer WebRTC DataChannel, DTLS-SRTP encrypted voice, ICE candidates via trickle, relay mode for IP privacy",
    "/verify safety number comparison, public key fingerprint verification, mutual authentication, trust-on-first-use model",
    "/shield security monitor detects tab switching, screen capture attempts, new device connections, alerts both peers instantly",
    "/cipher randomBytes(48) base64url room IDs, 384-bit entropy, HMAC-SHA1 TURN credentials, one-time invite links",
    "/tunnel encrypted WebSocket signaling, certificate pinning, TLS 1.3 transport, strict content security policy headers",
    "/stealth constant-rate padding to defeat traffic analysis, dummy message injection, timing attack resistance, covert channels",
    "/derive PBKDF2 with hardware-backed salt, Argon2id memory-hard KDF, secure enclave key storage, biometric unlock gates",
    "/purge automatic memory sanitization on disconnect, zero-persistence message storage, RAM-only operation, no disk writes",
    "/rotate symmetric ratchet with HKDF chains, Diffie-Hellman ratchet for forward secrecy, message key derivation per send",
    "/anonymize onion-routed relay hops, decoy traffic generation, plausible deniability through steganographic encoding layers",
    "/quantum post-quantum CRYSTALS-Kyber key encapsulation, hybrid X25519+ML-KEM, future-proof against quantum adversaries",
    "/attest remote attestation of peer integrity, zero-knowledge proof of identity without revealing secrets, ring signatures",
    "/seal authenticated encryption with associated data AEAD, GCM authentication tags, forgery-resistant MAC verification",
    "/erase cryptographic shredding of expired keys, secure memory deallocation, heap sanitization, anti-forensic countermeasures",
    "/route NAT traversal via STUN/TURN, ICE candidate gathering, peer reflexive discovery, relay fallback for symmetric NATs",
    "/signal X3DH extended triple Diffie-Hellman key agreement, prekey bundles, signed prekeys, one-time prekey consumption",
    "/chain hash-chain integrity verification, append-only authenticated log, Merkle tree commitment scheme, tamper evidence",
    "/noise Noise protocol framework XX pattern, handshake encryption, transport message confidentiality, identity hiding",
    "/destruct auto-destruct timer with cryptographic erasure, forward-secure deletion, no recovery possible after timeout",
    "/entropy hardware RNG seeded CSPRNG, Web Crypto API getRandomValues, entropy pool mixing, unpredictable nonce generation",
    "/cloak IP address masking through TURN relay, no direct peer connections in privacy mode, transport policy enforcement",
    "/mesh decentralized signaling with no single point of failure, distributed hash table peer discovery, gossip protocol relay",
    "/harden input validation and sanitization, XSS prevention, CSP nonce-based script execution, frame-ancestors restrictions",
    "/minimize data minimization by design, collect nothing, store nothing, log nothing, metadata-free communication protocol",
    "/ratchet double ratchet algorithm combining symmetric-key and Diffie-Hellman ratchets for optimal forward secrecy guarantees",
    "/verify mutual key verification through out-of-band safety number comparison, visual fingerprint matching, QR code scanning",
    "/ephemeral all cryptographic material exists only in volatile memory, session keys never touch persistent storage medium"
  ];

  // ── Shaders ──
  const VERT_SRC = `attribute vec4 aPos;
attribute vec2 aTex;
varying lowp vec2 vTex;
void main(){gl_Position=aPos;vTex=aTex;}`;

  const FRAG_SRC = `precision mediump float;
varying vec2 vTex;
uniform sampler2D uSamp;
uniform float uTime;
uniform vec2 uRes;

void main(){
  vec2 uv=vTex;

  // Subtle chromatic aberration (decays quickly)
  float d=0.002*exp(-uTime/600.0);
  float r=texture2D(uSamp,vec2(uv.x+d,uv.y)).r;
  float g=texture2D(uSamp,uv).g;
  float b=texture2D(uSamp,vec2(uv.x-d,uv.y)).b;
  vec4 c=vec4(r,g,b,1.0);

  // Soft scanlines
  float sl=max(0.0,sin(uv.y*uRes.y*0.8))*0.4;
  c.rgb=mix(c.rgb,c.rgb-vec3(sl),0.2);

  // Vignette — soft darkening at edges
  float v=1.0-length(uv-0.5)*0.6;
  c.rgb*=v;

  // Brightness + tone mapping
  c.rgb*=2.2;
  c.rgb=1.0-exp(-c.rgb);

  gl_FragColor=c;
}`;

  // ── Math helpers ──
  const { sin, cos, round, sqrt, max, floor, min, abs, atan2, asin } = Math;
  function lerp(a, b, t) { return a * (1 - t) + b * t; }
  function clamp(lo, v, hi) { return v < lo ? lo : v > hi ? hi : v; }
  function eoq(t) { return t * (2 - t); }

  // ── Geometric patterns (pixel-correct circle via shortDim normalization) ──
  function globePattern(px, py, shortR, t) {
    const r = sqrt(px * px + py * py) / shortR;
    const R = 0.65;
    if (r >= R) return 0;

    const z = sqrt(R * R - (px / shortR) * (px / shortR) - (py / shortR) * (py / shortR));
    const ct = cos(t), st = sin(t);
    const nxr = (px / shortR) * ct + z * st;
    const nzr = -(px / shortR) * st + z * ct;

    const lon = atan2(nzr, nxr);
    const lat = asin(clamp(-1, (py / shortR) / R, 1));

    const lonLine = abs(sin(lon * 10)) < 0.07 ? 1 : 0;
    const latLine = abs(sin(lat * 8)) < 0.07 ? 1 : 0;

    // Edge outline
    const edge = r > R * 0.88 ? 1 : 0;

    return max(lonLine, latLine, edge);
  }

  function ripplePattern(px, py, shortR, t) {
    const r = sqrt(px * px + py * py) / shortR;
    const r1 = (t * 0.1) % 1.8;
    const r2 = ((t * 0.1) + 0.9) % 1.8;
    // Thicker rings on small screens so they're visible
    const rw = max(0.02, 10 / shortR);
    return (abs(r - r1) < rw || abs(r - r2) < rw) ? 1 : 0;
  }

  // ── State ──
  let canvas, gl, offCvs, offCtx;
  let program, uTime, uRes, uSamp;
  let texture, aPos, aTex;
  let anim = null, startTime = 0;
  let useWebGL = false;
  let vw, vh, dpr;
  let isMobile = false;
  let lastFrame = 0;

  function init() {
    canvas = document.getElementById('ghost-bg');
    if (!canvas) return;

    vw = innerWidth;
    vh = innerHeight;
    dpr = min(devicePixelRatio || 1, 2);
    isMobile = 'ontouchstart' in window || vw < 600;

    // Try WebGL2
    gl = canvas.getContext('webgl2', { alpha: true, premultipliedAlpha: false });
    if (gl) {
      useWebGL = true;
      setupWebGL();
    } else {
      useWebGL = false;
    }

    offCvs = document.createElement('canvas');
    offCtx = offCvs.getContext('2d');

    resize();

    addEventListener('resize', onResize);
    document.addEventListener('visibilitychange', onVis);

    if (document.fonts) document.fonts.ready.then(() => {});

    startTime = performance.now();
    anim = requestAnimationFrame(loop);
  }

  let resizeTimer;
  function onResize() {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(resize, 150);
  }

  function resize() {
    vw = innerWidth;
    vh = innerHeight;

    if (useWebGL) {
      canvas.width = vw * dpr;
      canvas.height = vh * dpr;
      canvas.style.width = vw + 'px';
      canvas.style.height = vh + 'px';
      gl.viewport(0, 0, canvas.width, canvas.height);
    } else {
      canvas.width = vw;
      canvas.height = vh;
    }

    offCvs.width = vw * dpr;
    offCvs.height = vh * dpr;
  }

  function onVis() {
    if (document.hidden) { cancelAnimationFrame(anim); anim = null; }
    else { startTime = performance.now() - 1000; anim = requestAnimationFrame(loop); }
  }

  // ── WebGL setup ──
  function setupWebGL() {
    const vs = compile(gl.VERTEX_SHADER, VERT_SRC);
    const fs = compile(gl.FRAGMENT_SHADER, FRAG_SRC);
    if (!vs || !fs) { useWebGL = false; return; }

    program = gl.createProgram();
    gl.attachShader(program, vs);
    gl.attachShader(program, fs);
    gl.linkProgram(program);
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) { useWebGL = false; return; }
    gl.useProgram(program);

    const verts = new Float32Array([
      -1, -1,  0, 1,
       1, -1,  1, 1,
      -1,  1,  0, 0,
       1,  1,  1, 0
    ]);
    const buf = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buf);
    gl.bufferData(gl.ARRAY_BUFFER, verts, gl.STATIC_DRAW);

    aPos = gl.getAttribLocation(program, 'aPos');
    aTex = gl.getAttribLocation(program, 'aTex');
    gl.enableVertexAttribArray(aPos);
    gl.enableVertexAttribArray(aTex);
    gl.vertexAttribPointer(aPos, 2, gl.FLOAT, false, 16, 0);
    gl.vertexAttribPointer(aTex, 2, gl.FLOAT, false, 16, 8);

    texture = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, texture);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);

    uTime = gl.getUniformLocation(program, 'uTime');
    uRes = gl.getUniformLocation(program, 'uRes');
    uSamp = gl.getUniformLocation(program, 'uSamp');
    gl.uniform1i(uSamp, 0);
  }

  function compile(type, src) {
    const s = gl.createShader(type);
    gl.shaderSource(s, src);
    gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) {
      console.error(gl.getShaderInfoLog(s));
      gl.deleteShader(s);
      return null;
    }
    return s;
  }

  // ── Swirl rendering (2D canvas) ──
  function renderSwirl(ctx, w, h, elapsed) {
    const rotAngle = elapsed * 0.001;
    const logoAlpha = eoq(clamp(0, elapsed * 0.001 * 0.5, 1));
    const patternTime = elapsed * 0.0004;

    ctx.fillStyle = '#080808';
    ctx.fillRect(0, 0, w, h);

    // Adaptive font: smaller on phones for dense look
    const fontSize = w < 400 ? 8 : w < 700 ? 10 : 12;
    ctx.font = fontSize + 'px "JetBrains Mono",monospace';
    const charW = ctx.measureText('M').width;

    const numCols = floor(w / charW);
    const numRows = floor(h / fontSize);
    const linesLen = LINES.length;

    // Aspect-correct pattern coords: shortDim = shorter screen edge / 2
    const shortR = min(w, h) * 0.5;
    const cx = w * 0.5, cy = h * 0.5;

    // Logo in upper area (skip if screen too narrow)
    const logoFits = numCols >= LOGO[0].length + 4;
    const logoCOff = logoFits ? max(0, round((numCols - LOGO[0].length) / 2)) : 0;
    const logoROff = logoFits ? max(1, round(numRows * 0.15 - LOGO.length / 2)) : -99;

    for (let row = 0; row < numRows; row++) {
      let dimLine = '';
      let brightLine = '';
      let logoLine = '';
      let hasBright = false;

      const py = row * fontSize - cy; // pixel offset from center

      for (let col = 0; col < numCols; col++) {
        const px = col * charW - cx; // pixel offset from center
        const nx = col * 2 / numCols - 1;
        const ny = 1 - row * 2 / numRows;
        const dist = sqrt(nx * nx + ny * ny);

        // Swirl for character lookup
        const swirl = rotAngle * 0.08 / max(0.12, dist);
        const s = sin(swirl), c = cos(swirl);
        const rx = nx * c + ny * s;
        const ry = nx * s - ny * c;

        let srcCol = floor((rx + 1) / 2 * numCols);
        let srcRow = floor((ry + 1) / 2 * numRows);
        srcRow = ((srcRow % linesLen) + linesLen) % linesLen;

        let ch = (srcCol < 0 || srcCol >= LINES[srcRow].length)
          ? ' '
          : (LINES[srcRow][srcCol] ?? ' ');

        // Pattern: characters EXIST on shapes, absent elsewhere
        const gp = globePattern(px, py, shortR, patternTime);
        const rp = ripplePattern(px, py, shortR, patternTime);
        const onShape = gp > 0 || rp > 0;

        if (onShape) {
          brightLine += ch;
          dimLine += ' ';
          hasBright = true;
        } else {
          brightLine += ' ';
          dimLine += ch;
        }

        // Logo composite with fade-in morph
        if (row >= logoROff && row < logoROff + LOGO.length &&
            col >= logoCOff && col < logoCOff + LOGO[0].length) {
          const lc = col - logoCOff;
          const lr = row - logoROff;
          const lch = LOGO[lr][lc];
          if (lch !== ' ' || (lc > 0 && LOGO[lr][lc-1] !== ' ') ||
              (lc < LOGO[0].length-1 && LOGO[lr][lc+1] !== ' ')) {
            logoLine += String.fromCharCode(round(lerp(ch.charCodeAt(0), lch.charCodeAt(0), logoAlpha)));
          } else {
            logoLine += ' ';
          }
        }
      }

      const y = row * fontSize;

      // Dim background text (barely visible atmosphere)
      ctx.fillStyle = 'rgb(25,25,25)';
      ctx.font = fontSize + 'px "JetBrains Mono",monospace';
      ctx.fillText(dimLine, 0, y);

      // Bright shape text (shapes drawn BY characters)
      if (hasBright) {
        ctx.fillStyle = 'rgb(160,160,160)';
        ctx.fillText(brightLine, 0, y);
      }

      // Logo overlay
      if (row >= logoROff && row < logoROff + LOGO.length) {
        ctx.fillStyle = 'rgba(255,255,255,' + (logoAlpha * 0.9) + ')';
        ctx.font = 'bold ' + fontSize + 'px "JetBrains Mono",monospace';
        ctx.fillText(logoLine, logoCOff * charW, y);
      }
    }
  }

  // ── Animation loop ──
  function loop(ts) {
    anim = requestAnimationFrame(loop);

    // 30fps on mobile, 60fps on desktop
    const frameTime = isMobile ? 33 : 16;
    if (ts - lastFrame < frameTime) return;
    lastFrame = ts;

    const elapsed = ts - startTime;

    offCtx.setTransform(dpr, 0, 0, dpr, 0, 0);
    renderSwirl(offCtx, vw, vh, elapsed);

    if (useWebGL) {
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, offCvs);
      gl.uniform1f(uTime, elapsed);
      gl.uniform2f(uRes, canvas.width, canvas.height);
      gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
    } else {
      const ctx = canvas.getContext('2d');
      ctx.drawImage(offCvs, 0, 0, canvas.width, canvas.height);
    }
  }

  return { init };
})();

if (document.readyState === 'loading')
  document.addEventListener('DOMContentLoaded', GhostBG.init);
else GhostBG.init();