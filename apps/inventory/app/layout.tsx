import "./globals.css";
import type { Metadata } from "next";
import { Nav } from "@/lib/nav";

export const metadata: Metadata = {
  title: "Newvora Inventory",
  description: "Stock, locations, movements, transfers and counts for Indian SMBs",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>
        <div className="shell">
          <aside className="sidebar">
            <div className="brand">newvora <span>inventory</span></div>
            <Nav />
          </aside>
          <main className="main">{children}</main>
        </div>
      </body>
    </html>
  );
}
