# Whisper Pilot portal

Static download portal for Vercel. Release data and DMG links come from GitHub Releases at runtime.

## Local preview

Run any static file server from this folder, for example:

```sh
npx serve .
```

## Test

```sh
npm test
```

## Deploy to Vercel

Import `vertocode/whisper-pilot`, set **Root Directory** to `portal`, and leave framework preset as **Other**. No build command or environment variables are required.
