#include "slaveSocket.h"
#include "helper.h"
#include "openclHelper.h"
#include "socketHelper.h"
#include <poll.h>
#include <stdio.h>

int messageKernelSource(struct Interop* interop, int socketFd)
{
    int numStrings = 0;
    if (PrintErr(recv_p(socketFd, &numStrings, sizeof(int))))
        return -1;
    char** sources = (char**)malloc(numStrings * sizeof(char*));
    for (int source = 0; source < numStrings; source++)
        sources[source] = recv_str(socketFd);

    int result = PrintErr(newClContext(&interop->clContext, *interop, sources, numStrings));

    for (int source = 0; source < numStrings; source++)
        free(sources[source]);
    free(sources);

    return result;
}

int messageKernelInvoke(struct Interop* interop, int socketFd, struct ScreenPos screenPos)
{
    char* kernelName = recv_str(socketFd);
    if (kernelName == NULL)
        return -1;
    size_t launchSize[2];
    if (PrintErr(recv_p(socketFd, launchSize, sizeof(launchSize))))
    {
        free(kernelName);
        return -1;
    }
    for (int argIndex = 0;; argIndex++)
    {
        int arglen = 0;
        if (PrintErr(recv_p(socketFd, &arglen, sizeof(int))))
        {
            free(kernelName);
            return -1;
        }
        if (arglen == 0)
            break;
        else if (arglen == -1)
        {
            int bufferName = 0;
            if (PrintErr(recv_p(socketFd, &bufferName, sizeof(int))))
            {
                free(kernelName);
                return -1;
            }
            cl_mem memory = getMem(*interop, bufferName, NULL);
            if (memory == NULL)
            {
                free(kernelName);
                return -1;
            }

        }
        else if (arglen == -2)
        {
            if (PrintErr(setKernelArg(&interop->clContext, kernelName, argIndex++,
                            &screenPos.x, sizeof(int))))
            {
                free(kernelName);
                return -1;
            }
            if (PrintErr(setKernelArg(&interop->clContext, kernelName, argIndex++,
                            &screenPos.y, sizeof(int))))
            {
                free(kernelName);
                return -1;
            }
            if (PrintErr(setKernelArg(&interop->clContext, kernelName, argIndex++,
                            &screenPos.width, sizeof(int))))
            {
                free(kernelName);
                return -1;
            }
            if (PrintErr(setKernelArg(&interop->clContext, kernelName, argIndex++,
                            &screenPos.height, sizeof(int))))
            {
                free(kernelName);
                return -1;
            }
        }
        else
        {
            unsigned char arg[arglen];
            if (PrintErr(recv_p(socketFd, arg, arglen)))
            {
                free(kernelName);
                return -1;
            }
            if (PrintErr(setKernelArg(&interop->clContext, kernelName, argIndex, arg, arglen)))
            {
                free(kernelName);
                return -1;
            }
        }
    }
    int result = PrintErr(invokeKernel(&interop->clContext, *interop, kernelName, launchSize));

    free(kernelName);

    return result;
}

int slaveSocket(struct Interop* interop, int socketFd, struct ScreenPos screenPos)
{
    while (1)
    {
        struct pollfd poll_fd;
        poll_fd.events = POLLIN;
        poll_fd.fd = socketFd;
        int pollResult = poll(&poll_fd, 1, 0);
        if (PrintErr(pollResult == -1 && "poll()"))
            return -1;
        if (pollResult == 0 || !(poll_fd.revents & POLLIN))
            break;

        enum MessageType messageType;
        if (PrintErr(recv_p(socketFd, &messageType, sizeof(messageType))))
            return -1;

        switch (messageType)
        {
            case MessageNull:
                break;
            case MessageKernelSource:
                if (PrintErr(messageKernelSource(interop, socketFd)))
                    return -1;
                break;
            case MessageKernelInvoke:
                if (PrintErr(messageKernelInvoke(interop, socketFd, screenPos)))
                    return -1;
                break;
            case MessageMkBuffer:
                break;
            case MessageRmBuffer:
                break;
            case MessageDlBuffer:
                break;
            default:
                printf("Unknown message type %d\n", messageType);
                return -1;
        }
    }
    return 0;
}
