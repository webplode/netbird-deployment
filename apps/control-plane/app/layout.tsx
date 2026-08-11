import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Sleek Network Control",
  description: "Steampipe inventory and NetBird network operations.",
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
