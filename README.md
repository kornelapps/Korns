# Kornels Imagenes
Generador de imagenes para Android.
- Online: FLUX schnell en Cloudflare Workers AI (con cuenta gratis, engranaje de la app) + Pollinations como respaldo.
- Offline: Stable Diffusion 1.5 cuantizado (GGUF) con stable-diffusion.cpp (commit d637cfb) compilado para arm64
  por GitHub Actions y empaquetado como libsdcli.so. Modo Turbo con LCM-LoRA (4 pasos).
Sube a GitHub -> Actions -> descarga el artefacto `kornels-imagenes-apk`.
