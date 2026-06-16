'use client';

import { useEffect, useState } from 'react';
import { doc, onSnapshot } from 'firebase/firestore';
import { db } from '@/lib/firebase';
import { isPreferredProduct, rankProductsByPreferences } from '@/lib/demoProfiles';

interface Product {
  product_id: string;
  name: string;
  price: number;
  image_url?: string;
  purchase_url?: string;
  seller?: string;
}

interface SessionDocument {
  products: Product[];
  last_updated: { seconds: number; nanoseconds: number } | null;
}

interface ShoppingListProps {
  sessionId: string;
  preferenceTerms: string[];
}

export default function ShoppingList({ sessionId, preferenceTerms }: ShoppingListProps) {
  const [products, setProducts] = useState<Product[]>([]);
  const [lastUpdated, setLastUpdated] = useState<Date | null>(null);
  const [connectionError, setConnectionError] = useState<string | null>(null);
  const [isConnected, setIsConnected] = useState(false);

  useEffect(() => {
    if (!sessionId) return;

    const sessionRef = doc(db, 'LiveShoppingSessions', sessionId);

    const unsubscribe = onSnapshot(
      sessionRef,
      (snapshot) => {
        setIsConnected(true);
        setConnectionError(null);

        if (snapshot.exists()) {
          const data = snapshot.data() as SessionDocument;
          setProducts(data.products ?? []);

          if (data.last_updated) {
            setLastUpdated(new Date(data.last_updated.seconds * 1000));
          }
        } else {
          setProducts([]);
        }
      },
      (error) => {
        setIsConnected(false);
        setConnectionError(error.message);
      }
    );

    return () => {
      unsubscribe();
    };
  }, [sessionId]);

  const orderedProducts = rankProductsByPreferences(products, preferenceTerms);

  return (
    <div className="flex flex-col h-full bg-gray-900 text-white">
      <div className="flex items-center justify-between px-4 py-3 border-b border-gray-700">
        <h2 className="text-lg font-semibold tracking-wide">Shop</h2>
        <div className="flex items-center gap-2">
          {isConnected ? (
            <span className="flex items-center gap-1.5 text-xs font-bold text-cyan-300">
              <span className="relative flex h-2.5 w-2.5">
                <span className="animate-ping absolute inline-flex h-full w-full rounded-full bg-cyan-300 opacity-75" />
                <span className="relative inline-flex rounded-full h-2.5 w-2.5 bg-cyan-400" />
              </span>
              SYNCED
            </span>
          ) : (
            <span className="flex items-center gap-1.5 text-xs font-bold text-gray-500">
              <span className="inline-flex rounded-full h-2.5 w-2.5 bg-gray-600" />
              OFFLINE
            </span>
          )}
        </div>
      </div>

      {connectionError && (
        <div className="mx-4 mt-3 px-3 py-2 rounded-md bg-red-900/40 border border-red-700 text-red-300 text-sm">
          Connection error: {connectionError}
        </div>
      )}

      <div className="flex-1 overflow-y-auto px-4 py-3 space-y-3">
        {orderedProducts.length === 0 ? (
          <div className="flex flex-col items-center justify-center h-full gap-3 text-gray-500 py-16">
            <svg
              className="w-12 h-12 opacity-30"
              fill="none"
              stroke="currentColor"
              viewBox="0 0 24 24"
            >
              <path
                strokeLinecap="round"
                strokeLinejoin="round"
                strokeWidth={1.5}
                d="M2.25 3h1.386c.51 0 .955.343 1.087.836l.383 1.437M7.5 14.25a3 3 0 00-3 3h15.75m-12.75-3h11.218c1.121-2.3 2.1-4.684 2.924-7.138a60.114 60.114 0 00-16.536-1.84M7.5 14.25L5.106 5.272M6 20.25a.75.75 0 11-1.5 0 .75.75 0 011.5 0zm12.75 0a.75.75 0 11-1.5 0 .75.75 0 011.5 0z"
              />
            </svg>
            <p className="text-sm font-medium">Waiting for the first demo image...</p>
            <p className="text-xs opacity-60">Matched products will appear here after analysis</p>
          </div>
        ) : (
          orderedProducts.map((product) => {
            const preferred = isPreferredProduct(product, preferenceTerms);

            return (
              <div
                key={product.product_id}
                className="flex flex-col bg-gray-800 rounded-xl px-4 py-3 border border-gray-700 hover:border-gray-500 transition-colors"
              >
                <div className="flex items-center justify-between">
                  <div className="flex flex-col min-w-0 flex-1">
                    <p className="text-sm font-medium text-white leading-snug line-clamp-2">
                      {product.name}
                    </p>
                    <span className="text-xs text-gray-400 mt-0.5">
                      {preferred ? 'Preferred match' : 'Matched'}
                    </span>
                  </div>
                  <span className="text-base font-bold text-green-400 ml-4 flex-shrink-0">
                    ${product.price.toFixed(2)}
                  </span>
                </div>
                {product.purchase_url && (
                  <div className="flex items-center justify-between mt-2 pt-2 border-t border-gray-700">
                    <span className="text-xs text-gray-500 truncate">
                      {product.seller ?? ''}
                    </span>
                    <a
                      href={product.purchase_url}
                      target="_blank"
                      rel="noopener noreferrer"
                      className="text-xs font-bold text-emerald-400 border border-emerald-700 rounded-lg px-3 py-1 hover:bg-emerald-900/30 transition-colors ml-3 flex-shrink-0"
                      onClick={(e) => e.stopPropagation()}
                    >
                      Buy →
                    </a>
                  </div>
                )}
              </div>
            );
          })
        )}
      </div>

      {lastUpdated && (
        <div className="px-4 py-2 border-t border-gray-700 text-xs text-gray-500 text-right">
          Last sync {lastUpdated.toLocaleTimeString()}
        </div>
      )}
    </div>
  );
}
