'use client';

import { useState, useEffect, useCallback, useRef } from 'react';
import { useWallet } from '@/hooks/useWallet';
import { fetchSTXBalance } from '@/lib/api';
import { toast } from 'react-hot-toast';

const MICROSTX_DIVISOR = 1_000_000;
const REFRESH_INTERVAL = 30000;
const BALANCE_DECIMALS = 4;

const FIAT_OPTIONS = [
  { label: 'USD', rate: 0.42 },
  { label: 'EUR', rate: 0.39 },
  { label: 'GBP', rate: 0.34 },
];

export default function WalletBalance() {
  const { address, isConnected } = useWallet();
  const [balance, setBalance] = useState<number | null>(null);
  const [displayBalance, setDisplayBalance] = useState<number>(0);
  const [isLoading, setIsLoading] = useState(true);
  const [isRefreshing, setIsRefreshing] = useState(false);
  const [lastUpdated, setLastUpdated] = useState<Date | null>(null);
  const [error, setError] = useState<string | null>(null);

  // Fiat currency state
  const [fiat, setFiat] = useState(FIAT_OPTIONS[0]);

  // Dark mode toggle
  const [darkMode, setDarkMode] = useState(true);

  const rafRef = useRef<number | null>(null);

  const animateBalance = useCallback((from: number, to: number, duration = 300) => {
    const start = performance.now();
    const step = (timestamp: number) => {
      const progress = Math.min((timestamp - start) / duration, 1);
      setDisplayBalance(from + (to - from) * progress);
      if (progress < 1) rafRef.current = requestAnimationFrame(step);
    };
    rafRef.current = requestAnimationFrame(step);
  }, []);

  const fetchBalance = useCallback(async () => {
    if (!address) return;
    setIsRefreshing(true);
    setError(null);

    try {
      const data = await fetchSTXBalance(address);
      const stx = data.balance / MICROSTX_DIVISOR;
      setBalance(stx);
      animateBalance(displayBalance, stx);
      setLastUpdated(new Date());
    } catch (err) {
      console.error(err);
      setError('Failed to fetch balance. Retry?');
      toast.error('Failed to fetch wallet balance.');
    } finally {
      setIsLoading(false);
      setIsRefreshing(false);
    }
  }, [address, displayBalance, animateBalance]);

  useEffect(() => {
    if (address) {
      fetchBalance();
      const interval = setInterval(fetchBalance, REFRESH_INTERVAL);
      return () => {
        clearInterval(interval);
        if (rafRef.current) cancelAnimationFrame(rafRef.current);
      };
    }
  }, [address, fetchBalance]);

  const formatTimeAgo = (date: Date) => {
    const seconds = Math.floor((new Date().getTime() - date.getTime()) / 1000);
    if (seconds < 60) return 'just now';
    const minutes = Math.floor(seconds / 60);
    return `${minutes}m ago`;
  };

  const handleCopyAddress = () => {
    if (address) {
      navigator.clipboard.writeText(address);
      toast.success('Address copied to clipboard');
    }
  };

  if (!isConnected) return null;

  const fiatValue = balance ? (balance * fiat.rate).toFixed(2) : '0.00';

  return (
    <div className={`${darkMode ? 'bg-gray-900/90 text-white' : 'bg-white text-gray-900'} border border-purple-500/20 rounded-2xl p-6 backdrop-blur-sm relative overflow-hidden transition-colors duration-300`}>
      <div className="absolute -top-12 -right-12 w-24 h-24 bg-purple-500/10 rounded-full blur-2xl pointer-events-none" />

      {/* Dark/Light toggle */}
      <div className="absolute top-4 right-4">
        <button
          className="p-1 bg-gray-700/30 dark:bg-gray-200/30 rounded-full"
          onClick={() => setDarkMode(!darkMode)}
          title="Toggle Dark/Light Mode"
        >
          {darkMode ? '🌙' : '☀️'}
        </button>
      </div>

      <div className="relative">
        {/* Header */}
        <div className="flex items-center justify-between mb-4">
          <div className="flex items-center gap-2">
            <div className="w-8 h-8 bg-gradient-to-br from-purple-500 to-pink-500 rounded-lg flex items-center justify-center">
              <span className="text-sm">💰</span>
            </div>
            <span className="font-medium">Wallet Balance</span>
          </div>
          <div className="flex items-center gap-2">
            <button 
              onClick={fetchBalance}
              disabled={isRefreshing}
              className="p-2 text-gray-400 hover:text-purple-400 hover:bg-purple-500/10 rounded-lg transition-all disabled:opacity-50"
              title="Refresh balance"
            >
              <svg 
                className={`w-4 h-4 ${isRefreshing ? 'animate-spin' : ''}`} 
                fill="none" 
                stroke="currentColor" 
                viewBox="0 0 24 24"
              >
                <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15" />
              </svg>
            </button>
            <button
              onClick={handleCopyAddress}
              className="p-2 text-gray-400 hover:text-purple-400 hover:bg-purple-500/10 rounded-lg transition-all"
              title="Copy wallet address"
            >
              📋
            </button>
          </div>
        </div>

        {/* Balance Display */}
        <div className="text-center py-4">
          {isLoading ? (
            <div className="animate-pulse">
              <div className="h-10 w-32 bg-gray-700 rounded-lg mx-auto mb-2" />
              <div className="h-4 w-20 bg-gray-700 rounded mx-auto" />
            </div>
          ) : error ? (
            <div className="text-red-500 text-sm">{error}</div>
          ) : (
            <>
              <p className={`text-4xl font-bold transition-all ${isRefreshing ? 'opacity-50' : ''}`}>
                {displayBalance.toFixed(BALANCE_DECIMALS)}
                <span className="text-2xl text-purple-400 ml-1">STX</span>
              </p>
              <p className="text-sm mt-1">
                ≈ {fiatValue} {fiat.label}
              </p>

              {/* Fiat selector */}
              <select
                className="mt-2 px-2 py-1 rounded-lg border border-gray-400 bg-gray-800/20 text-sm text-white"
                value={fiat.label}
                onChange={(e) => {
                  const selected = FIAT_OPTIONS.find(f => f.label === e.target.value);
                  if (selected) setFiat(selected);
                }}
              >
                {FIAT_OPTIONS.map((f) => (
                  <option key={f.label} value={f.label}>{f.label}</option>
                ))}
              </select>
            </>
          )}
        </div>

        {/* Quick Actions */}
        <div className="grid grid-cols-2 gap-3 mt-4">
          <button className="flex items-center justify-center gap-2 py-3 bg-purple-600/20 hover:bg-purple-600 text-purple-400 hover:text-white rounded-xl font-medium transition-all">
            <span>↗️</span>
            <span className="text-sm">Send</span>
          </button>
          <button className="flex items-center justify-center gap-2 py-3 bg-gray-700/50 hover:bg-gray-600 text-gray-300 hover:text-white rounded-xl font-medium transition-all">
            <span>↙️</span>
            <span className="text-sm">Receive</span>
          </button>
        </div>

        {/* Last Updated */}
        {lastUpdated && (
          <p className="text-center text-xs mt-4">
            Last updated {formatTimeAgo(lastUpdated)}
          </p>
        )}
      </div>
    </div>
  );
}
