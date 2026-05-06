import { useState, useEffect } from 'react'
import { NavLink, Outlet } from 'react-router-dom'
import { Button } from './ui'
import { useAuth } from '../contexts/useAuth'
import {
  Boxes,
  LayoutDashboard,
  Server,
  ArrowRightLeft,
  Activity,
  ScrollText,
  Network,
  Users,
  PanelLeftClose,
  PanelLeftOpen,
  LogOut,
} from 'lucide-react'

const NAV_ITEMS = [
  { to: '/dashboard', label: 'Dashboard', Icon: LayoutDashboard },
  { to: '/infrastructure', label: 'Infrastructure', Icon: Server },
  { to: '/inventory', label: 'Migrate VMs', Icon: ArrowRightLeft },
  { to: '/migration-jobs', label: 'Monitoring', Icon: Activity },
  { to: '/logs', label: 'Logs', Icon: ScrollText },
  { to: '/settings', label: 'Network Config', Icon: Network },
]

function Layout() {
  const { user, logout } = useAuth()
  const isSuperAdmin = user?.role === 'SUPER_ADMIN'
  const initials = user?.username?.slice(0, 2)?.toUpperCase() || 'VM'
  
  // Initialize sidebar state from localStorage
  const [isOpen, setIsOpen] = useState(() => {
    const saved = localStorage.getItem('sidebar_open')
    return saved !== null ? JSON.parse(saved) : true
  })

  // Persist sidebar state to localStorage
  useEffect(() => {
    localStorage.setItem('sidebar_open', JSON.stringify(isOpen))
  }, [isOpen])

  function toggleTheme() {
    const root = document.documentElement
    const next = root.dataset.theme === 'dark' ? 'light' : 'dark'
    root.dataset.theme = next
    localStorage.setItem('vmigrate-theme', next)
  }

  return (
    <div className="app-layout" data-sidebar-open={isOpen}>
      <aside className="sidebar" data-open={isOpen} aria-label="Primary navigation">
        {/* Toggle Button */}
        <div className="sidebar-header">
          <button
            className="sidebar-toggle"
            onClick={() => setIsOpen(!isOpen)}
            aria-label={isOpen ? 'Collapse sidebar' : 'Expand sidebar'}
            aria-expanded={isOpen}
            title={isOpen ? 'Collapse sidebar' : 'Expand sidebar'}
          >
            {isOpen ? (
              <PanelLeftClose className="w-5 h-5" strokeWidth={2} />
            ) : (
              <PanelLeftOpen className="w-5 h-5" strokeWidth={2} />
            )}
          </button>
        </div>

        {/* Brand Logo */}
        <div className="brand-block">
          <div className="brand-mark">
            <Boxes className="w-6 h-6" strokeWidth={2} aria-hidden="true" />
          </div>
          {isOpen && (
            <div className="brand-text">
              <p className="brand-kicker">OpenStack</p>
              <h1 className="brand-title">VMigrate</h1>
            </div>
          )}
        </div>

        {/* Navigation */}
        <nav className="nav-links">
          {NAV_ITEMS.map((item) => {
            const Icon = item.Icon
            return (
              <NavLink
                key={item.to}
                to={item.to}
                className={({ isActive }) => `nav-link ${isActive ? 'active' : ''}`}
                data-tooltip={isOpen ? '' : item.label}
              >
                <Icon className="nav-icon w-5 h-5 flex-shrink-0" strokeWidth={2} aria-hidden="true" />
                {isOpen && <span className="nav-label">{item.label}</span>}
              </NavLink>
            )
          })}
          
          {/* Users link (admin only) */}
          {isSuperAdmin && (
            <NavLink
              to="/users"
              className={({ isActive }) => `nav-link ${isActive ? 'active' : ''}`}
              data-tooltip={isOpen ? '' : 'Users'}
            >
              <Users className="nav-icon w-5 h-5 flex-shrink-0" strokeWidth={2} aria-hidden="true" />
              {isOpen && <span className="nav-label">Users</span>}
            </NavLink>
          )}
        </nav>

        {/* User Section */}
        <div className="sidebar-footer">
          <div 
            className="user-card"
            title={isOpen ? '' : `${user?.username} (${user?.role})`}
          >
            <div className="user-avatar">{initials}</div>
            {isOpen && (
              <div className="user-info">
                <p className="user-name">{user?.username}</p>
                <p className="user-role">{user?.role}</p>
              </div>
            )}
          </div>
          <button
            className="logout-btn"
            onClick={logout}
            title={isOpen ? '' : 'Logout'}
            aria-label="Logout"
          >
            <LogOut className="w-5 h-5" strokeWidth={2} aria-hidden="true" />
            {isOpen && <span>Logout</span>}
          </button>
        </div>
      </aside>

      <div className="workspace">
        <header className="topbar">
          <div>
            <p className="eyebrow">Migration control plane</p>
            <strong>Production cockpit</strong>
          </div>
          <div className="topbar-actions">
            <span className="system-status"><span aria-hidden="true" /> API reachable</span>
            <Button variant="ghost" type="button" onClick={toggleTheme} aria-label="Toggle dark mode">
              Theme
            </Button>
          </div>
        </header>

        <main className="content">
          <Outlet />
        </main>
      </div>
    </div>
  )
}

export default Layout
