import "./globals.css";
import type { Metadata } from "next";
import { Nav } from "@/lib/nav";

export const metadata: Metadata = {
  title: "Inventory · Newvora",
  description: "Stock, locations, movements, transfers and counts for Indian SMBs",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <head>
        {/* Brand fonts (same pair as newvora.in). Loaded at runtime so builds
            never depend on network access; the CSS stack falls back cleanly. */}
        <link rel="preconnect" href="https://fonts.googleapis.com" />
        <link rel="preconnect" href="https://fonts.gstatic.com" crossOrigin="anonymous" />
        <link
          href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=Sora:wght@600;700&display=swap"
          rel="stylesheet"
        />
      </head>
      <body>
        <div className="shell">
          <aside className="sidebar">
            <div className="brand">new<span>vora</span></div>
            <Nav />
          </aside>
          <main className="main">{children}</main>
        </div>
      </body>
    </html>
  );
}
