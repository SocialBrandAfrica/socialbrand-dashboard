/** @type {import('tailwindcss').Config} */
module.exports = {
  content: [
    './src/pages/**/*.{js,ts,jsx,tsx,mdx}',
    './src/components/**/*.{js,ts,jsx,tsx,mdx}',
    './src/app/**/*.{js,ts,jsx,tsx,mdx}',
  ],
  theme: {
    extend: {
      colors: {
        brand: {
          green:  '#2E7D32',
          red:    '#C62828',
          amber:  '#F57F17',
          blue:   '#1565C0',
          dark:   '#1A1A2E',
          card:   '#16213E',
          border: '#0F3460',
        },
      },
    },
  },
  plugins: [],
}
