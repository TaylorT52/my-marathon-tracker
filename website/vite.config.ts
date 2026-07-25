import {defineConfig, loadEnv} from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig(({mode}) => {
  const env = loadEnv(mode, process.cwd(), "");
  return {
    plugins: [react()],
    build: {
      outDir: "dist/client",
      emptyOutDir: true,
    },
    define: {
      "process.env.NEXT_PUBLIC_FIREBASE_API_KEY":
        JSON.stringify(env.NEXT_PUBLIC_FIREBASE_API_KEY),
      "process.env.NEXT_PUBLIC_FIREBASE_AUTH_DOMAIN":
        JSON.stringify(env.NEXT_PUBLIC_FIREBASE_AUTH_DOMAIN),
      "process.env.NEXT_PUBLIC_FIREBASE_PROJECT_ID":
        JSON.stringify(env.NEXT_PUBLIC_FIREBASE_PROJECT_ID),
      "process.env.NEXT_PUBLIC_FIREBASE_APP_ID":
        JSON.stringify(env.NEXT_PUBLIC_FIREBASE_APP_ID),
    },
  };
});
