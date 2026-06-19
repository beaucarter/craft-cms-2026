import { defineConfig } from 'vite';
import tailwindcss from '@tailwindcss/vite';

export default defineConfig({
  plugins: [tailwindcss()],
  build: {
    emptyOutDir: true,
    outDir: 'web/dist',
    rollupOptions: {
      input: 'src/js/app.js',
      output: {
        entryFileNames: 'app.js',
        assetFileNames: 'app.[ext]',
      },
    },
  },
});

