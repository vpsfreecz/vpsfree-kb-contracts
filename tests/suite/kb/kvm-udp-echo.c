#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/types.h>
#include <unistd.h>

static int parse_family(const char *value)
{
    if (strcmp(value, "4") == 0) {
        return AF_INET;
    }
    if (strcmp(value, "6") == 0) {
        return AF_INET6;
    }

    fprintf(stderr, "invalid IP family: %s\n", value);
    exit(EXIT_FAILURE);
}

static in_port_t parse_port(const char *value)
{
    char *end = NULL;
    unsigned long port;

    errno = 0;
    port = strtoul(value, &end, 10);
    if (errno != 0 || end == value || *end != '\0' || port == 0 ||
        port > 65535) {
        fprintf(stderr, "invalid UDP port: %s\n", value);
        exit(EXIT_FAILURE);
    }

    return htons((in_port_t)port);
}

static void parse_address(int family, const char *value, in_port_t port,
                          struct sockaddr_storage *storage,
                          socklen_t *storage_length)
{
    int status;

    memset(storage, 0, sizeof(*storage));
    if (family == AF_INET) {
        struct sockaddr_in *address = (struct sockaddr_in *)storage;

        address->sin_family = AF_INET;
        address->sin_port = port;
        status = inet_pton(family, value, &address->sin_addr);
        *storage_length = sizeof(*address);
    } else {
        struct sockaddr_in6 *address = (struct sockaddr_in6 *)storage;

        address->sin6_family = AF_INET6;
        address->sin6_port = port;
        status = inet_pton(family, value, &address->sin6_addr);
        *storage_length = sizeof(*address);
    }

    if (status != 1) {
        fprintf(stderr, "invalid IP address: %s\n", value);
        exit(EXIT_FAILURE);
    }
}

static int open_socket(int family)
{
    int fd;
    int one = 1;

    fd = socket(family, SOCK_DGRAM, 0);
    if (fd == -1) {
        perror("socket");
        exit(EXIT_FAILURE);
    }
    if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one)) == -1) {
        perror("setsockopt(SO_REUSEADDR)");
        exit(EXIT_FAILURE);
    }
    if (family == AF_INET6 &&
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &one, sizeof(one)) == -1) {
        perror("setsockopt(IPV6_V6ONLY)");
        exit(EXIT_FAILURE);
    }

    return fd;
}

static int run_server(int family, const char *address_value,
                      const char *port_value)
{
    struct sockaddr_storage local;
    socklen_t local_length;
    int fd;

    parse_address(family, address_value, parse_port(port_value), &local,
                  &local_length);
    fd = open_socket(family);
    if (bind(fd, (struct sockaddr *)&local, local_length) == -1) {
        perror("bind");
        return EXIT_FAILURE;
    }
    fprintf(stderr, "UDP echo server listening on %s port %s\n",
            address_value, port_value);

    for (;;) {
        struct sockaddr_storage peer;
        socklen_t peer_length = sizeof(peer);
        char buffer[65536];
        ssize_t received;
        ssize_t sent;

        do {
            received = recvfrom(fd, buffer, sizeof(buffer), 0,
                                (struct sockaddr *)&peer, &peer_length);
        } while (received == -1 && errno == EINTR);
        if (received == -1) {
            perror("recvfrom");
            return EXIT_FAILURE;
        }

        do {
            sent = sendto(fd, buffer, (size_t)received, 0,
                          (struct sockaddr *)&peer, peer_length);
        } while (sent == -1 && errno == EINTR);
        if (sent != received) {
            if (sent == -1) {
                perror("sendto");
            } else {
                fprintf(stderr, "short UDP response\n");
            }
            return EXIT_FAILURE;
        }
        fprintf(stderr, "UDP echo server on %s returned %zd bytes\n",
                address_value, sent);
    }
}

static int run_client(int family, const char *address_value,
                      const char *port_value, const char *payload)
{
    struct sockaddr_storage peer;
    socklen_t peer_length;
    struct timeval timeout = {
        .tv_sec = 2,
        .tv_usec = 0,
    };
    size_t payload_length = strlen(payload);
    char buffer[65536];
    ssize_t received;
    ssize_t sent;
    int fd;

    if (payload_length > sizeof(buffer)) {
        fprintf(stderr, "UDP payload is too large\n");
        return EXIT_FAILURE;
    }
    parse_address(family, address_value, parse_port(port_value), &peer,
                  &peer_length);
    fd = open_socket(family);
    if (connect(fd, (struct sockaddr *)&peer, peer_length) == -1) {
        perror("connect");
        return EXIT_FAILURE;
    }
    if (setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) ==
        -1) {
        perror("setsockopt(SO_RCVTIMEO)");
        return EXIT_FAILURE;
    }

    do {
        sent = send(fd, payload, payload_length, 0);
    } while (sent == -1 && errno == EINTR);
    if (sent != (ssize_t)payload_length) {
        if (sent == -1) {
            perror("send");
        } else {
            fprintf(stderr, "short UDP request\n");
        }
        return EXIT_FAILURE;
    }

    do {
        received = recv(fd, buffer, sizeof(buffer), 0);
    } while (received == -1 && errno == EINTR);
    if (received == -1) {
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            fprintf(stderr, "timed out waiting for UDP echo from %s port %s\n",
                    address_value, port_value);
        } else {
            perror("recv");
        }
        return EXIT_FAILURE;
    }
    if ((size_t)received != payload_length ||
        memcmp(buffer, payload, payload_length) != 0) {
        fprintf(stderr, "UDP response did not match the request\n");
        return EXIT_FAILURE;
    }

    return EXIT_SUCCESS;
}

int main(int argc, char **argv)
{
    int family;

    if (argc < 2) {
        goto usage;
    }
    if (strcmp(argv[1], "server") == 0 && argc == 5) {
        family = parse_family(argv[2]);
        return run_server(family, argv[3], argv[4]);
    }
    if (strcmp(argv[1], "client") == 0 && argc == 6) {
        family = parse_family(argv[2]);
        return run_client(family, argv[3], argv[4], argv[5]);
    }

usage:
    fprintf(stderr,
            "usage: %s server 4|6 ADDRESS PORT | "
            "client 4|6 ADDRESS PORT PAYLOAD\n",
            argv[0]);
    return EXIT_FAILURE;
}
