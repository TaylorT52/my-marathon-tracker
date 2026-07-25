import type {Metadata} from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "RunAlong — Live Race Tracking",
  description: "Follow a runner's live pace, location, finish estimate, and race-day updates.",
};

export default function RootLayout({children}: Readonly<{children: React.ReactNode}>) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
