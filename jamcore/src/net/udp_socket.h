// Minimal IPv4 UDP socket (Winsock / POSIX) for the AOO audio link.
#pragma once
#include <cstdint>
#include <cstring>
#include <string>

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
using jam_sock_t = SOCKET;
#define JAM_BAD_SOCK INVALID_SOCKET
#else
#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>
using jam_sock_t = int;
#define JAM_BAD_SOCK (-1)
#endif

namespace jam {

class UdpSocket {
	jam_sock_t s = JAM_BAD_SOCK;
	uint16_t port = 0;

public:
	~UdpSocket() { close(); }

	bool open(uint16_t p_port) {
#ifdef _WIN32
		static bool wsa = [] { WSADATA d; return WSAStartup(MAKEWORD(2, 2), &d) == 0; }();
		if (!wsa) return false;
#endif
		s = ::socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
		if (s == JAM_BAD_SOCK) return false;
		int buf = 1 << 20;
		setsockopt(s, SOL_SOCKET, SO_RCVBUF, (const char *)&buf, sizeof(buf));
		setsockopt(s, SOL_SOCKET, SO_SNDBUF, (const char *)&buf, sizeof(buf));
		sockaddr_in a{};
		a.sin_family = AF_INET;
		a.sin_addr.s_addr = htonl(INADDR_ANY);
		a.sin_port = htons(p_port);
		if (::bind(s, (sockaddr *)&a, sizeof(a)) != 0) {
			close();
			return false;
		}
		socklen_t len = sizeof(a);
		getsockname(s, (sockaddr *)&a, &len);
		port = ntohs(a.sin_port);
#ifdef _WIN32
		u_long nb = 1;
		ioctlsocket(s, FIONBIO, &nb);
		// Don't fail recvfrom with WSAECONNRESET when a peer's port is closed.
		BOOL off = FALSE;
		DWORD ret = 0;
		WSAIoctl(s, _WSAIOW(IOC_VENDOR, 12), &off, sizeof(off), nullptr, 0, &ret, nullptr, nullptr);
#else
		fcntl(s, F_SETFL, fcntl(s, F_GETFL, 0) | O_NONBLOCK);
#endif
		return true;
	}

	void close() {
		if (s == JAM_BAD_SOCK) return;
#ifdef _WIN32
		::closesocket(s);
#else
		::close(s);
#endif
		s = JAM_BAD_SOCK;
	}

	bool is_open() const { return s != JAM_BAD_SOCK; }
	uint16_t get_port() const { return port; }

	// Waits until a packet is readable or the timeout passes.
	bool wait(int timeout_ms) {
#ifdef _WIN32
		fd_set set;
		FD_ZERO(&set);
		FD_SET(s, &set);
		timeval tv{0, timeout_ms * 1000};
		return ::select(0, &set, nullptr, nullptr, &tv) > 0;
#else
		pollfd p{s, POLLIN, 0};
		return ::poll(&p, 1, timeout_ms) > 0;
#endif
	}

	int recv(uint8_t *buf, int size, sockaddr_in &from) {
		socklen_t len = sizeof(from);
		return (int)::recvfrom(s, (char *)buf, size, 0, (sockaddr *)&from, &len);
	}

	int send(const void *data, int size, const void *addr, int addrlen) {
		return (int)::sendto(s, (const char *)data, size, 0, (const sockaddr *)addr, (socklen_t)addrlen);
	}

	static bool make_addr(const std::string &ip, uint16_t p, sockaddr_in &out) {
		memset(&out, 0, sizeof(out));
		out.sin_family = AF_INET;
		out.sin_port = htons(p);
		return inet_pton(AF_INET, ip.c_str(), &out.sin_addr) == 1;
	}
};

} // namespace jam
