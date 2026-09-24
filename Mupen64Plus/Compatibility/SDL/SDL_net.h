/*
 Copyright (c) 2026, OpenEmu Team

 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
 * Redistributions of source code must retain the above copyright
 notice, this list of conditions and the following disclaimer.
 * Redistributions in binary form must reproduce the above copyright
 notice, this list of conditions and the following disclaimer in the
 documentation and/or other materials provided with the distribution.
 * Neither the name of the OpenEmu Team nor the
 names of its contributors may be used to endorse or promote products
 derived from this software without specific prior written permission.

 THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
 EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

/*
 * A stand-in for the parts of SDL_net that Mupen64Plus' netplay code uses,
 * built on plain BSD sockets so the core doesn't need to link SDL_net.
 * Behaviour follows SDL_net 2: addresses and ports are kept in network byte
 * order, UDP receives never block, TCP receives do.
 */

#ifndef SDL_NET_H
#define SDL_NET_H

#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>

typedef struct {
    uint32_t host; /* network byte order */
    uint16_t port; /* network byte order */
} IPaddress;

/* Mupen64Plus casts this to its own copy of SDL_net's internal struct
 * { int ready; int channel; } to reach the socket (to set IP_TOS), so the first
 * two fields must keep that layout. */
struct _OEUDPsocket {
    int ready;
    int channel;
    int has_destination;
    struct sockaddr_in destination;
};
typedef struct _OEUDPsocket *UDPsocket;

struct _TCPsocket {
    int fd;
};
typedef struct _TCPsocket *TCPsocket;

typedef struct {
    int channel;
    uint8_t *data;
    int len;
    int maxlen;
    int status;
    IPaddress address;
} UDPpacket;

static inline int SDLNet_Init(void) { return 0; }
static inline void SDLNet_Quit(void) { }

static inline int SDLNet_ResolveHost(IPaddress *address, const char *host, uint16_t port)
{
    address->port = htons(port);
    if (host == NULL) {
        address->host = INADDR_ANY;
        return 0;
    }

    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    struct addrinfo *result = NULL;
    if (getaddrinfo(host, NULL, &hints, &result) != 0 || result == NULL) {
        address->host = INADDR_NONE;
        return -1;
    }
    address->host = ((struct sockaddr_in *)result->ai_addr)->sin_addr.s_addr;
    freeaddrinfo(result);
    return 0;
}

static inline void SDLNet_Write16(uint16_t value, void *area)
{
    uint8_t *p = (uint8_t *)area;
    p[0] = (uint8_t)(value >> 8);
    p[1] = (uint8_t)value;
}

static inline void SDLNet_Write32(uint32_t value, void *area)
{
    uint8_t *p = (uint8_t *)area;
    p[0] = (uint8_t)(value >> 24);
    p[1] = (uint8_t)(value >> 16);
    p[2] = (uint8_t)(value >> 8);
    p[3] = (uint8_t)value;
}

static inline uint16_t SDLNet_Read16(const void *area)
{
    const uint8_t *p = (const uint8_t *)area;
    return (uint16_t)((p[0] << 8) | p[1]);
}

static inline uint32_t SDLNet_Read32(const void *area)
{
    const uint8_t *p = (const uint8_t *)area;
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

#pragma mark UDP

static inline UDPsocket SDLNet_UDP_Open(uint16_t port)
{
    UDPsocket sock = (UDPsocket)calloc(1, sizeof(*sock));
    if (sock == NULL)
        return NULL;

    sock->ready = 1;
    sock->channel = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock->channel < 0) {
        free(sock);
        return NULL;
    }

    struct sockaddr_in local;
    memset(&local, 0, sizeof(local));
    local.sin_family = AF_INET;
    local.sin_addr.s_addr = INADDR_ANY;
    local.sin_port = htons(port);
    if (bind(sock->channel, (struct sockaddr *)&local, sizeof(local)) < 0) {
        close(sock->channel);
        free(sock);
        return NULL;
    }

    fcntl(sock->channel, F_SETFL, fcntl(sock->channel, F_GETFL) | O_NONBLOCK);
    return sock;
}

/* Netplay only ever binds one destination, so the channel number is ignored. */
static inline int SDLNet_UDP_Bind(UDPsocket sock, int channel, const IPaddress *address)
{
    (void)channel;
    if (sock == NULL || address == NULL)
        return -1;

    memset(&sock->destination, 0, sizeof(sock->destination));
    sock->destination.sin_family = AF_INET;
    sock->destination.sin_addr.s_addr = address->host;
    sock->destination.sin_port = address->port;
    sock->has_destination = 1;
    return 0;
}

static inline void SDLNet_UDP_Unbind(UDPsocket sock, int channel)
{
    (void)channel;
    if (sock != NULL)
        sock->has_destination = 0;
}

static inline int SDLNet_UDP_Send(UDPsocket sock, int channel, UDPpacket *packet)
{
    (void)channel;
    if (sock == NULL || packet == NULL || !sock->has_destination)
        return 0;

    ssize_t sent = sendto(sock->channel, packet->data, (size_t)packet->len, 0,
                          (const struct sockaddr *)&sock->destination, sizeof(sock->destination));
    packet->status = (int)sent;
    return sent == packet->len ? 1 : 0;
}

/* Returns 1 if a packet was received, 0 if none is waiting, -1 on error. */
static inline int SDLNet_UDP_Recv(UDPsocket sock, UDPpacket *packet)
{
    if (sock == NULL || packet == NULL)
        return -1;

    struct sockaddr_in from;
    socklen_t fromLength = sizeof(from);
    ssize_t received = recvfrom(sock->channel, packet->data, (size_t)packet->maxlen, 0,
                                (struct sockaddr *)&from, &fromLength);
    if (received < 0)
        return (errno == EAGAIN || errno == EWOULDBLOCK) ? 0 : -1;

    packet->len = (int)received;
    packet->status = (int)received;
    packet->channel = -1;
    packet->address.host = from.sin_addr.s_addr;
    packet->address.port = from.sin_port;
    return 1;
}

static inline void SDLNet_UDP_Close(UDPsocket sock)
{
    if (sock == NULL)
        return;
    close(sock->channel);
    free(sock);
}

static inline UDPpacket *SDLNet_AllocPacket(int size)
{
    UDPpacket *packet = (UDPpacket *)calloc(1, sizeof(UDPpacket));
    if (packet == NULL)
        return NULL;
    packet->data = (uint8_t *)calloc(1, (size_t)size);
    if (packet->data == NULL) {
        free(packet);
        return NULL;
    }
    packet->maxlen = size;
    return packet;
}

static inline void SDLNet_FreePacket(UDPpacket *packet)
{
    if (packet == NULL)
        return;
    free(packet->data);
    free(packet);
}

#pragma mark TCP

static inline TCPsocket SDLNet_TCP_Open(IPaddress *address)
{
    if (address == NULL)
        return NULL;

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0)
        return NULL;

    struct sockaddr_in remote;
    memset(&remote, 0, sizeof(remote));
    remote.sin_family = AF_INET;
    remote.sin_addr.s_addr = address->host;
    remote.sin_port = address->port;
    if (connect(fd, (struct sockaddr *)&remote, sizeof(remote)) < 0) {
        close(fd);
        return NULL;
    }

    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));

    TCPsocket sock = (TCPsocket)calloc(1, sizeof(*sock));
    if (sock == NULL) {
        close(fd);
        return NULL;
    }
    sock->fd = fd;
    return sock;
}

/* Sends everything or fails, like SDL_net. Returns the number of bytes sent. */
static inline int SDLNet_TCP_Send(TCPsocket sock, const void *data, int length)
{
    if (sock == NULL)
        return -1;

    const uint8_t *bytes = (const uint8_t *)data;
    int sent = 0;
    while (sent < length) {
        ssize_t result = send(sock->fd, bytes + sent, (size_t)(length - sent), 0);
        if (result < 0) {
            if (errno == EINTR)
                continue;
            break;
        }
        sent += (int)result;
    }
    return sent;
}

/* Blocks until some data arrives. Returns the byte count, or <= 0 on error or disconnect. */
static inline int SDLNet_TCP_Recv(TCPsocket sock, void *data, int maxLength)
{
    if (sock == NULL)
        return -1;

    ssize_t result;
    do {
        result = recv(sock->fd, data, (size_t)maxLength, 0);
    } while (result < 0 && errno == EINTR);
    return (int)result;
}

static inline void SDLNet_TCP_Close(TCPsocket sock)
{
    if (sock == NULL)
        return;
    close(sock->fd);
    free(sock);
}

#endif /* SDL_NET_H */
